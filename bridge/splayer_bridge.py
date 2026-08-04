#!/usr/bin/env python3
"""
splayer_bridge.py — SPlayer WebSocket → stdout JSON-lines bridge
for the DMS SPlayer Lyrics plugin.

架构：
    SPlayer (ws://host:port)
        │  WebSocket JSON events
        ▼
    splayer_bridge.py   (自动重连，指数退避)
        │  stdout: 每行一个 JSON 对象
        ▼
    Quickshell Process + SplitParser("\\n")  →  QML 状态 → 歌词显示

输出协议（stdout，一行一个 JSON，UTF-8）：
    {"type": "__event", "data": <SPlayer 原始事件对象>}
    {"type": "__status", "data": {"connected": true, "host": ..., "port": ...}}
    {"type": "__status", "data": {"connected": false}}
    {"type": "__error",  "data": {"message": "..."}}

依赖：python3 + websockets 库（pip install websockets）
用法：python3 splayer_bridge.py [host] [port]
"""

import argparse
import asyncio
import json
import sys

import websockets

# 多久没有收到任何消息就认为连接已死并重连（秒）。
# SPlayer 播放时 progress-change 会周期性推送，暂停时也通常有状态事件，
# 因此一段很长的静默几乎总是意味着连接异常。
SILENCE_TIMEOUT = 120.0

# 重连退避参数
RETRY_MIN = 1.0
RETRY_MAX = 30.0


def emit(obj):
    """向 stdout 输出一行 JSON 并立即 flush。"""
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def log(msg):
    print(f"[splayer-bridge] {msg}", file=sys.stderr, flush=True)


async def consume(ws):
    """
    读取一条消息并转发。返回 True 表示连接仍可用，False 表示连接已结束。
    """
    try:
        raw = await asyncio.wait_for(ws.recv(), timeout=SILENCE_TIMEOUT)
    except asyncio.TimeoutError:
        # 静默超时：连接大概率已死，主动断开触发重连
        log(f"{SILENCE_TIMEOUT:.0f}s 内无任何消息，判定连接失效")
        return False
    except websockets.ConnectionClosed:
        return False

    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        log(f"收到非 JSON 消息，忽略: {raw[:200]!r}")
        return True

    emit({"type": "__event", "data": payload})
    return True


async def run(host, port):
    uri = f"ws://{host}:{port}"
    delay = RETRY_MIN

    while True:
        try:
            log(f"正在连接 {uri} …")
            # ping_interval=None: 不发送应用层 ping，
            # 避免 SPlayer 不响应协议 ping 时被误判断线。
            async with websockets.connect(uri, ping_interval=None) as ws:
                log("已连接")
                delay = RETRY_MIN
                emit({
                    "type": "__status",
                    "data": {"connected": True, "host": host, "port": port},
                })
                while await consume(ws):
                    pass
                log("连接已断开")
        except (websockets.WebSocketException, OSError) as exc:
            log(f"连接失败: {exc}")

        emit({"type": "__status", "data": {"connected": False}})
        log(f"{delay:.0f}s 后重连…")
        await asyncio.sleep(delay)
        delay = min(delay * 2, RETRY_MAX)


def main():
    ap = argparse.ArgumentParser(
        description="SPlayer WebSocket bridge for DMS SPlayer Lyrics"
    )
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", default="25885", type=int)
    args = ap.parse_args()

    try:
        asyncio.run(run(args.host, args.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
