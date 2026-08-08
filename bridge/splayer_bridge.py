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
import urllib.request
import urllib.error
import hashlib

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
    except Exception:
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
    track = np.get("track", {})
    artwork = track.get("artwork")
    cover = (artwork[0].get("src", "") if artwork else "") if isinstance(artwork, list) else ""
    return {
        "name": track.get("title", ""),
        "title": np.get("title", track.get("title", "")),
        "artistName": track.get("artist", ""),
        "artist": track.get("artist", ""),
        "albumName": track.get("album", ""),
        "album": track.get("album", ""),
        "cover": cover,
        "playStatus": np.get("state") == "playing",
        "currentTime": np.get("position", 0),
        "duration": np.get("duration", 0),
        "lyricAvailable": np.get("lyricAvailable", False),
        "lyricLineCount": np.get("lyricLineCount", 0),
    }


def _lyrics_to_lrc_data(lyrics_resp):
    """把 SPlayer-Next /api/lyrics 响应转为 lrcData 格式。"""
    lines = []
    for item in lyrics_resp:
        time_ms = item.get("time", 0)
        text = item.get("word", "")
        words = item.get("yrc", [])
        lines.append({
            "startTime": time_ms,
            "endTime": time_ms + 5000,
            "text": text,
            "lyric": text,
            "translated": item.get("translatedLyric", ""),
            "roman": item.get("romanLyric", ""),
            "words": [
                {"startTime": w.get("startTime", 0), "endTime": w.get("endTime", 0), "word": w.get("word", "")}
                for w in (words or [])
            ],
        })
    return lines


async def run(host, http_port, ws_port):
    delay = RETRY_MIN
    base_url = f"http://{host}:{http_port}"
    asyncio.get_running_loop().create_task(stdin_forwarder(host, http_port))

    last_song_id = None
    last_lyrics_hash = None
    last_position = 0
    last_state = None

    while True:
        try:
            info = http_get(f"{base_url}/api/info", timeout=3)
            if info is None:
                raise Exception("无法连接到 SPlayer-Next HTTP API")

            log(f"已连接 {host}:{http_port}")
            delay = RETRY_MIN
            emit({"type": "__status", "data": {"connected": True, "host": host, "httpPort": http_port, "wsPort": ws_port}})

            # 初始化当前状态
            np = http_get(f"{base_url}/api/now-playing")
            if np:
                emit({"type": "__event", "data": {"type": "song-info", "data": _now_playing_to_song_info(np)}})
                track = np.get("track", {})
                last_song_id = f"{track.get('title','')}|{track.get('artist','')}"
                last_state = np.get("state")
                last_position = np.get("position", 0)

            while True:
                await asyncio.sleep(STATUS_POLL_INTERVAL_MS / 1000.0)

                np = http_get(f"{base_url}/api/now-playing")
                if not np:
                    continue

                state = np.get("state", "unknown")
                position = np.get("position", 0)
                duration = np.get("duration", 0)
                track = np.get("track", {})
                song_id = f"{track.get('title','')}|{track.get('artist','')}"

                # 歌曲切换
                if song_id != last_song_id:
                    last_song_id = song_id
                    last_lyrics_hash = None
                    last_position = position
                    last_state = state

                    artwork = track.get("artwork")
                    cover = (artwork[0].get("src", "") if artwork else "") if isinstance(artwork, list) else ""

                    song_data = {
                        "title": track.get("title", ""),
                        "name": track.get("title", ""),
                        "artist": track.get("artist", ""),
                        "album": track.get("album", ""),
                        "cover": cover,
                        "duration": duration,
                        "currentTime": position,
                        "playStatus": state == "playing",
                    }
                    emit({"type": "__event", "data": {"type": "song-change", "data": song_data}})
                    emit({"type": "__event", "data": {"type": "song-info", "data": {
                        **song_data,
                        "artistName": track.get("artist", ""),
                        "albumName": track.get("album", ""),
                    }}})

                    lyrics = http_get(f"{base_url}/api/lyrics")
                    if lyrics:
                        lrc_data = _lyrics_to_lrc_data(lyrics)
                        h = hashlib.md5(json.dumps(lrc_data, ensure_ascii=False).encode()).hexdigest()
                        last_lyrics_hash = h
                        emit({"type": "__event", "data": {"type": "lyric-change", "data": {"lrcData": lrc_data}}})
                    continue

                # 状态变化
                if state != last_state:
                    last_state = state
                    emit({"type": "__event", "data": {"type": "status-change", "data": {"status": state == "playing"}}})

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
    ap = argparse.ArgumentParser(description="SPlayer-Next HTTP bridge for DMS SPlayer Lyrics")
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("http_port", nargs="?", default="14558", type=int)
    ap.add_argument("ws_port", nargs="?", default="25885", type=int)
    args = ap.parse_args()

    try:
        asyncio.run(run(args.host, args.http_port, args.ws_port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
