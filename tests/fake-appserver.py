#!/usr/bin/env python3
"""A minimal stand-in for the Codex app-server, for testing codex-inflight.sh.

Speaks just enough of the protocol to answer one client: the websocket upgrade,
`initialize`, and `thread/list`. Thread statuses are passed on argv so a test can
describe exactly the shape it wants to exercise.

    fake-appserver.py <socket-path> <status> [<status> ...]
    fake-appserver.py <socket-path> --rpc-error
"""
import base64, hashlib, json, os, socket, struct, sys

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(conn, size):
    chunks = []
    while size:
        chunk = conn.recv(size)
        if not chunk:
            raise RuntimeError("closed")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


def send_text(conn, text):
    payload = text.encode()
    n = len(payload)
    if n < 126:
        header = bytes((0x81, n))
    elif n <= 0xFFFF:
        header = bytes((0x81, 126)) + struct.pack("!H", n)
    else:
        header = bytes((0x81, 127)) + struct.pack("!Q", n)
    conn.sendall(header + payload)


def recv_text(conn):
    first, second = recv_exact(conn, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(conn, 8))[0]
    if second & 0x80:
        mask = recv_exact(conn, 4)
        data = bytes(v ^ mask[i % 4] for i, v in enumerate(recv_exact(conn, length)))
    else:
        data = recv_exact(conn, length)
    if (first & 0x0F) != 1:
        return None
    return data.decode()


def main():
    path, args = sys.argv[1], sys.argv[2:]
    rpc_error = "--rpc-error" in args
    statuses = [a for a in args if a != "--rpc-error"]

    if os.path.exists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    # The parent waits for this line so the test never races the listener.
    sys.stdout.write("ready\n")
    sys.stdout.flush()

    conn, _ = server.accept()
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = conn.recv(4096)
        if not chunk:
            return
        request += chunk
    key = ""
    for line in request.decode(errors="replace").split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    accept = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()
    conn.sendall(
        ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
         f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())

    while True:
        line = recv_text(conn)
        if line is None:
            break
        message = json.loads(line)
        method, request_id = message.get("method"), message.get("id")
        if method == "initialize":
            send_text(conn, json.dumps({"jsonrpc": "2.0", "id": request_id, "result": {}}))
        elif method == "thread/list":
            if rpc_error:
                send_text(conn, json.dumps({"jsonrpc": "2.0", "id": request_id,
                                            "error": {"code": -32603, "message": "boom"}}))
                break
            data = [{"id": f"thread-{i}", "status": {"type": s}}
                    for i, s in enumerate(statuses)]
            send_text(conn, json.dumps({"jsonrpc": "2.0", "id": request_id,
                                        "result": {"data": data}}))
            break
        else:
            send_text(conn, json.dumps({"jsonrpc": "2.0", "id": request_id, "result": {}}))
    conn.close()


main()
