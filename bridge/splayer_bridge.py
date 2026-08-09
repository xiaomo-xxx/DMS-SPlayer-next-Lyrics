#!/usr/bin/env python3
"""
splayer_bridge.py — SPlayer-Next HTTP polling → stdout JSON-lines bridge
for the DMS SPlayer Lyrics plugin (fork of ayyyyano/DMS-SPlayer-Lyrics).

用法：python3 splayer_bridge.py [host] [http_port] [ws_port]
    host:       SPlayer-Next 地址（默认 127.0.0.1）
    http_port:  HTTP API 端口（默认 14558）
    ws_port:    WebSocket 端口（默认 25885，兼容 QML 原配置，但本桥不再用）
"""

import argparse
import asyncio
import json
import sys
import time
import urllib.request
import urllib.error
import hashlib
import hashlib
import os
import signal
import traceback

TRACE_LOG = "/tmp/splayer_bridge_trace.log"

def _trace(msg):
    try:
        with open(TRACE_LOG, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] pid={os.getpid()} {msg}\n")
    except Exception:
        pass
# 轮询间隔（毫秒）
STATUS_POLL_INTERVAL_MS = 500

RETRY_MIN = 1.0
RETRY_MAX = 30.0


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def log(msg):
    print(f"[splayer-bridge] {msg}", file=sys.stderr, flush=True)


def http_get(url, timeout=3.0):
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return None


def http_post(url, data, timeout=3.0):
    try:
        body = json.dumps(data).encode("utf-8")
        req = urllib.request.Request(
            url, data=body,
            headers={"Content-Type": "application/json", "Accept": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


async def heartbeat_loop(interval=2.0):
    """看门狗心跳：只要进程活着就每 interval 秒 emit 一条 __heartbeat。

    QML 侧用「连续 N 秒无任何输出」判定 bridge 卡死（如内部轮询死循环），
    所以即使 SPlayer 未连接 / 暂停播放 / 重连退避期间也必须持续发心跳。
    """
    while True:
        await asyncio.sleep(interval)
        emit({"type": "__heartbeat", "data": {"ts": int(time.time() * 1000)}})


async def http_get_async(url, timeout=3.0):
    """同步 http_get 的非阻塞包装：在线程池执行，避免阻塞 asyncio 事件循环。

    关键：SPlayer API 慢响应/超时时，若直接同步调用会卡住整个事件循环，
    连带 heartbeat 断流，QML 看门狗会误判 bridge 卡死并强制重启
    （表现为歌词界面周期性"抽搐"）。
    """
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, http_get, url, timeout)


async def stdin_forwarder(host, http_port):
    """读取 stdin 中的 JSON 行，转发给 SPlayer-Next（控制命令）。"""
    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            await asyncio.sleep(0.2)
            continue
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue

        op = payload.get("type") or payload.get("op", "")
        data = payload.get("data", {})

        if op == "control":
            cmd = data.get("command", "")
            url = f"http://{host}:{http_port}/api/"
            if cmd == "toggle":
                url += "play"
            elif cmd in ("play", "pause", "stop", "next", "prev"):
                url += cmd
            elif cmd == "seek":
                pos = data.get("positionMs")
                if pos is not None:
                    loop.run_in_executor(None, lambda p=pos: http_post(
                        f"http://{host}:{http_port}/api/seek", {"positionMs": p}
                    ))
                continue
            loop.run_in_executor(None, lambda u=url: http_post(u, {}))

        elif op == "get-song-info":
            np = loop.run_in_executor(None, lambda: http_get(
                f"http://{host}:{http_port}/api/now-playing"
            ))
            if np:
                emit({"type": "__event", "data": {"type": "song-info", "data": _now_playing_to_song_info(np)}})


def _now_playing_to_song_info(np):
    """把 SPlayer-Next /api/now-playing 响应转为 SPlayer 桌面版 song-info 格式。"""
    track = np.get("track", {})
    artists = track.get("artists", [])
    artist_str = "/".join(a.get("name", "") for a in artists) if artists else ""

    # 封面：优先 coverOriginal，其次 cover
    cover = track.get("coverOriginal") or track.get("cover", "")

    return {
        "name": track.get("title", ""),
        "title": np.get("title", track.get("title", "")),
        "artistName": artist_str,
        "artist": artist_str,
        "albumName": (track.get("album") or {}).get("name", ""),
        "album": (track.get("album") or {}).get("name", ""),
        "cover": cover,
        "playStatus": np.get("playing", False),
        "currentTime": np.get("position", 0),
        "duration": track.get("duration", 0),
        "lyricAvailable": np.get("lyricAvailable", False),
        "lyricLineCount": np.get("lyricLineCount", 0),
    }


def _lyrics_to_lrc_data(lyrics_resp):
    """把 SPlayer-Next /api/lyrics 响应转为 lrcData 格式（兼容 QML 歌词解析）。

    SPlayer-Next lyrics 格式（实际）：
    {
      "lyric": [
        {
          "words": [{ "word": "字", "startTime": ms, "endTime": ms }],
          "translatedLyric": "翻译文本",
          "romanLyric": "罗马音文本",
          "startTime": ms,
          "endTime": ms,
          "isBG": false,
          "isDuet": false,
          "language": "zh-CN"
        },
        ...
      ]
    }
    """
    raw_lines = lyrics_resp.get("lyric", [])
    lines = []
    for item in raw_lines:
        words = item.get("words", [])
        start_time = item.get("startTime", 0)
        end_time = item.get("endTime", 0)

        # isBG=true 表示非人声/纯音乐，跳过不显示
        is_bg = item.get("isBG", False)

        # 取可显示文本：优先用 words 连起来，其次用 translatedLyric
        if words:
            text = "".join(w.get("word", "") for w in words)
        elif item.get("translatedLyric"):
            text = item.get("translatedLyric", "")
        else:
            text = ""

        lines.append({
            "startTime": start_time,
            "endTime": end_time if end_time > 0 else start_time + 5000,
            "text": text,
            "lyric": text,
            "translated": item.get("translatedLyric", ""),
            "roman": item.get("romanLyric", ""),
            "words": [
                {
                    "startTime": w.get("startTime", 0),
                    "endTime": w.get("endTime", 0),
                    "word": w.get("word", "")
                }
                for w in words
            ],
            "isBG": is_bg,
        })
    # 过滤掉纯音乐行（isBG=True 且无翻译）
    return [l for l in lines if not l["isBG"]]


async def run(host, http_port, ws_port):
    delay = RETRY_MIN
    base_url = f"http://{host}:{http_port}"
    asyncio.get_running_loop().create_task(stdin_forwarder(host, http_port))
    asyncio.get_running_loop().create_task(heartbeat_loop())

    last_song_id = None
    last_lyrics_hash = None
    last_position = 0
    last_playing = None

    while True:
        try:
            info = await http_get_async(f"{base_url}/api/info", timeout=3)
            if info is None:
                raise Exception("无法连接到 SPlayer-Next HTTP API")

            log(f"已连接 {host}:{http_port}")
            delay = RETRY_MIN
            emit({"type": "__status", "data": {"connected": True, "host": host, "httpPort": http_port, "wsPort": ws_port}})

            # 初始化当前状态
            np = await http_get_async(f"{base_url}/api/now-playing")
            if np:
                track = np.get("track", {})
                artists = track.get("artists", [])
                artist_str = "/".join(a.get("name", "") for a in artists) if artists else ""
                song_id = f"{track.get('title','')}|{artist_str}"

                emit({"type": "__event", "data": {"type": "song-info", "data": _now_playing_to_song_info(np)}})

                # 立即请求歌词（bridge 启动时歌曲可能已在播放，不会触发 song-change）
                lyrics = await http_get_async(f"{base_url}/api/lyrics")
                if lyrics:
                    lrc_data = _lyrics_to_lrc_data(lyrics)
                    last_lyrics_hash = hashlib.md5(json.dumps(lrc_data, ensure_ascii=False).encode()).hexdigest()
                    emit({"type": "__event", "data": {"type": "lyric-change", "data": {"lrcData": lrc_data}}})

                last_song_id = song_id
                last_playing = np.get("playing", False)
                last_position = np.get("position", 0)

            while True:
                await asyncio.sleep(STATUS_POLL_INTERVAL_MS / 1000.0)

                np = await http_get_async(f"{base_url}/api/now-playing")
                if not np:
                    continue

                track = np.get("track", {})
                artists = track.get("artists", [])
                artist_str = "/".join(a.get("name", "") for a in artists) if artists else ""

                position = np.get("position", 0)
                duration = track.get("duration", 0)
                playing = np.get("playing", False)
                song_id = f"{track.get('title','')}|{artist_str}"

                # 歌曲切换
                if song_id != last_song_id:
                    last_song_id = song_id
                    last_lyrics_hash = None
                    last_position = position
                    last_playing = playing

                    cover = track.get("coverOriginal") or track.get("cover", "")
                    song_data = {
                        "title": track.get("title", ""),
                        "name": track.get("title", ""),
                        "artist": artist_str,
                        "album": (track.get("album") or {}).get("name", ""),
                        "cover": cover,
                        "duration": duration,
                        "currentTime": position,
                        "playStatus": playing,
                    }
                    emit({"type": "__event", "data": {"type": "song-change", "data": song_data}})
                    emit({"type": "__event", "data": {"type": "song-info", "data": {
                        **song_data,
                        "artistName": artist_str,
                        "albumName": (track.get("album") or {}).get("name", ""),
                    }}})

                    # 换歌后立即尝试拉歌词；SPlayer 换歌瞬间歌词可能还没就绪
                    # （返回空 lyric 或仍是上一首的 trackId），此时保持
                    # last_lyrics_hash=None，由下方「歌词就绪重试」在后续轮询中补拉。
                    track_id = str(track.get("id", ""))
                    lyrics = await http_get_async(f"{base_url}/api/lyrics")
                    if lyrics and str(lyrics.get("trackId", "")) == track_id:
                        lrc_data = _lyrics_to_lrc_data(lyrics)
                        if lrc_data:
                            last_lyrics_hash = hashlib.md5(json.dumps(lrc_data, ensure_ascii=False).encode()).hexdigest()
                            emit({"type": "__event", "data": {"type": "lyric-change", "data": {"lrcData": lrc_data}}})
                    continue

                # 歌词就绪重试：换歌后 SPlayer 歌词未就绪（空/旧 trackId）时，
                # 每轮轮询补拉一次，直到拿到当前歌的歌词。已拿到则不再请求。
                if last_lyrics_hash is None:
                    track_id = str(track.get("id", ""))
                    lyrics = await http_get_async(f"{base_url}/api/lyrics")
                    if lyrics and str(lyrics.get("trackId", "")) == track_id:
                        lrc_data = _lyrics_to_lrc_data(lyrics)
                        if lrc_data:
                            last_lyrics_hash = hashlib.md5(json.dumps(lrc_data, ensure_ascii=False).encode()).hexdigest()
                            emit({"type": "__event", "data": {"type": "lyric-change", "data": {"lrcData": lrc_data}}})

                # 状态变化
                if playing != last_playing:
                    last_playing = playing
                    emit({"type": "__event", "data": {"type": "status-change", "data": {"status": playing}}})

                # 进度变化
                if abs(position - last_position) >= 200:
                    last_position = position
                    emit({"type": "__event", "data": {"type": "progress-change", "data": {
                        "currentTime": position,
                        "duration": duration,
                    }}})

        except Exception as exc:
            log(f"连接失败: {exc}")

        emit({"type": "__status", "data": {"connected": False}})
        log(f"{delay:.0f}s 后重连…")
        await asyncio.sleep(delay)
        delay = min(delay * 2, RETRY_MAX)


def main():
    _trace("启动")
    ap = argparse.ArgumentParser(description="SPlayer-Next HTTP bridge for DMS SPlayer Lyrics")
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("http_port", nargs="?", default="14558", type=int)
    ap.add_argument("ws_port", nargs="?", default="25885", type=int)
    args = ap.parse_args()

    def _on_term(signum, frame):
        _trace(f"收到信号 {signum} ({signal.Signals(signum).name})")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    try:
        asyncio.run(run(args.host, args.http_port, args.ws_port))
    except SystemExit:
        pass
    except KeyboardInterrupt:
        pass
    except Exception:
        _trace("未捕获异常退出: " + traceback.format_exc())
        raise
    finally:
        _trace("退出")


if __name__ == "__main__":
    main()
