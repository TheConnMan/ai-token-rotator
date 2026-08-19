#!/usr/bin/env bash
# Report Codex work that is in flight right now, one thread id per line.
#
# The app-server is the only component that knows about every running turn. Its
# threads come from an external dispatcher, the drain controller, the CLI dispatcher and Codex Desktop
# alike, so asking it directly covers all of them without any dispatcher having to
# register its work anywhere. That is what makes this safe for an external dispatcher, which
# records nothing in the the drain controller database.
#
# Contract expected by CODEX_INFLIGHT_CMD:
#   stdout non-empty, exit 0 -> work is in flight, do not swap
#   stdout empty,     exit 0 -> the coast is clear
#   exit non-zero            -> unknown, which the rotator treats as in flight
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "$HERE/codex-lib.sh"

# No app-server means no turns are running, which is a real answer, not an unknown.
[ -S "$CODEX_APPSERVER_SOCKET" ] || exit 0
[ -n "$(codex_appserver_pid)" ] || exit 0

python3 - "$CODEX_APPSERVER_SOCKET" <<'PY'
import json, os, socket, struct, sys

sock_path = sys.argv[1]

def recv_exact(sock, size):
    chunks = []
    while size:
        chunk = sock.recv(size)
        if not chunk:
            raise RuntimeError("app-server closed the connection")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)

def send_text(sock, text):
    payload = text.encode()
    mask = os.urandom(4)
    n = len(payload)
    if n < 126:
        header = bytes((0x81, 0x80 | n))
    elif n <= 0xFFFF:
        header = bytes((0x81, 0x80 | 126)) + struct.pack("!H", n)
    else:
        header = bytes((0x81, 0x80 | 127)) + struct.pack("!Q", n)
    sock.sendall(header + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(payload)))

def recv_text(sock):
    first, second = recv_exact(sock, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    if second & 0x80:
        mask = recv_exact(sock, 4)
        data = recv_exact(sock, length)
        data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
    else:
        data = recv_exact(sock, length)
    if (first & 0x0F) != 1:
        return None
    return data.decode(errors="replace")

def rpc(sock, request_id, method, params):
    send_text(sock, json.dumps(
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}))
    while True:
        line = recv_text(sock)
        if line is None:
            continue
        message = json.loads(line)
        if message.get("id") != request_id:
            continue
        if "error" in message:
            raise RuntimeError("app-server error: " + json.dumps(message["error"]))
        return message.get("result", {})

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(20)
try:
    sock.connect(sock_path)
    sock.sendall(
        b"GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
        b"Connection: Upgrade\r\nSec-WebSocket-Key: cnRvdGF0b3Jwcm9iZTAxMg==\r\n"
        b"Sec-WebSocket-Version: 13\r\n\r\n")
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("app-server closed during the websocket handshake")
        response += chunk
    if b"101" not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError("app-server refused the websocket upgrade")
    rpc(sock, 1, "initialize", {
        "clientInfo": {"name": "claude-token-rotator", "title": "rotator inflight probe",
                       "version": "1"},
        "capabilities": {"experimentalApi": True}})
    threads = rpc(sock, 2, "thread/list", {}).get("data", []) or []
finally:
    sock.close()

# Observed vocabulary: "active" is running a turn, "idle" is loaded but running
# nothing, "notLoaded" is evicted. Only the two known-quiet states clear the swap, so
# a status this was never taught holds instead of authorising a kill. Listing the
# quiet states rather than matching "active" is what keeps that default safe; an
# earlier version inverted it and reported a completed idle thread as in flight
# forever, which would have wedged rotation permanently.
QUIET = {"idle", "notLoaded"}

for thread in threads:
    status = (thread.get("status") or {}).get("type")
    if status not in QUIET:
        print(thread.get("id", ""))
PY
