"""A single HTTP/1.1 request on an ephemeral loopback port. No external sockets."""
import signal
import socket
import sys

signal.alarm(12)
with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    print(server.getsockname()[1], flush=True)
    conn, _ = server.accept()
    with conn:
        conn.settimeout(5)
        request = conn.makefile("rb")
        assert request.readline() == b"POST /stream HTTP/1.1\r\n"
        headers = {}
        for line in iter(request.readline, b"\r\n"):
            key, value = line.split(b":", 1)
            headers[key.lower()] = value.strip()
        assert headers[b"x-fixture"] == b"test"
        assert request.read(int(headers[b"content-length"])) == b"body"
        conn.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/event-stream\r\n\r\n")
        conn.sendall("data: 🌱\r\n".encode())
        if sys.argv[1] == "finish":
            # Client must process the complete first event before we send EOF.
            assert sys.stdin.buffer.readline() == b"next\n"
            conn.sendall(b"data: last")
        else:
            # No EOF or more data until the transport actually closes its end.
            try:
                assert request.read(1) == b""
            except ConnectionResetError:
                pass
