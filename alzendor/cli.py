"""Terminal client: python -m alzendor.cli [ws://localhost:8001/ws]

A thin client for trying things out; it speaks the same protocol as the web
client (see alzendor/session.py) but doesn't reconnect on its own.
"""

import asyncio
import getpass
import json
import sys
import threading

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed


def read_lines(loop: asyncio.AbstractEventLoop, queue: asyncio.Queue) -> None:
    """Feeds stdin lines into the queue from a daemon thread (None at EOF)."""
    for line in sys.stdin:
        loop.call_soon_threadsafe(queue.put_nowait, line.rstrip("\n"))
    loop.call_soon_threadsafe(queue.put_nowait, None)


async def log_in(ws) -> dict:
    while True:
        choice = (await asyncio.to_thread(input, "(l)og in or (r)egister? ")).strip().lower()
        kind = "register" if choice.startswith("r") else "login"
        name = await asyncio.to_thread(input, "Name: ")
        password = await asyncio.to_thread(getpass.getpass, "Password: ")
        await ws.send(json.dumps({"type": kind, "name": name, "password": password}))
        reply = json.loads(await ws.recv())
        if reply["type"] == "auth_ok":
            return reply
        print(reply.get("message", reply))


async def show_events(ws) -> None:
    try:
        async for raw in ws:
            message = json.loads(raw)
            if message["type"] == "event" and "text" in message["event"]:
                print(message["event"]["text"])
            elif message["type"] == "error":
                print("!", message["message"])
    except ConnectionClosed:
        pass
    print(f"[disconnected: {ws.close_reason or 'connection lost'}]")


async def main(url: str) -> None:
    async with connect(url) as ws:
        welcome = await log_in(ws)
        print(f"Connected to {welcome['server']} as {welcome['name']}. Type 'help' for commands.")
        lines: asyncio.Queue = asyncio.Queue()
        threading.Thread(target=read_lines, args=(asyncio.get_running_loop(), lines), daemon=True).start()
        events = asyncio.create_task(show_events(ws))
        while not events.done():
            reader = asyncio.create_task(lines.get())
            await asyncio.wait({reader, events}, return_when=asyncio.FIRST_COMPLETED)
            if not reader.done():
                reader.cancel()
                break
            if reader.result() is None:
                await ws.close()
                break
            await ws.send(json.dumps({"type": "cmd", "text": reader.result()}))
        await events


if __name__ == "__main__":
    try:
        asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "ws://localhost:8001/ws"))
    except (KeyboardInterrupt, EOFError):
        pass
