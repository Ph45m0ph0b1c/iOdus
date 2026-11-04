#!/usr/bin/env python3
"""Loopback TCP bridge from the Wine runtime to xodus-service.

Wine 7.7 (the GPTK Wine) has no AF_UNIX sockets, so xgameruntime cannot reach
/tmp/xodus.sock. The runtime can use a TCP bridge instead: it connects to
127.0.0.1:XODUS_BRIDGE_PORT and sends XODUS_BRIDGE_KEY (64 hex characters)
first. This bridge checks the key and then forwards all bytes to the socket.
The logic is the same as startXodusBridge in Xodus Nexus (xodus-service.ts).

Usage: xodus-bridge.py <env file> [socket path]
The env file gets XODUS_BRIDGE_PORT and XODUS_BRIDGE_KEY (mode 0600).
"""
import asyncio
import hmac
import os
import secrets
import sys

ENV_FILE = sys.argv[1]
SOCKET = sys.argv[2] if len(sys.argv) > 2 else "/tmp/xodus.sock"
KEY = secrets.token_hex(32).encode("ascii")


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_reader, client_writer):
    try:
        supplied = await asyncio.wait_for(client_reader.readexactly(len(KEY)), timeout=10)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError):
        client_writer.close()
        return
    if not hmac.compare_digest(supplied, KEY):
        client_writer.close()
        return
    try:
        up_reader, up_writer = await asyncio.open_unix_connection(SOCKET)
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(pipe(client_reader, up_writer), pipe(up_reader, client_writer))


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    fd = os.open(ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(f"XODUS_BRIDGE_PORT={port}\nXODUS_BRIDGE_KEY={KEY.decode()}\n")
    print(f"bridge ready on 127.0.0.1:{port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
