#!/usr/bin/env python3
"""Small scenario-driven Unix socket server for transport tests."""

import json
import os
import socket
import sys
import time


def send_json(connection, value):
    connection.sendall(json.dumps(value, separators=(",", ":")).encode() + b"\n")


def receive_request(connection):
    message = bytearray()
    while b"\n" not in message:
        chunk = connection.recv(4096)
        if not chunk:
            raise RuntimeError("client closed before sending a complete request")
        message.extend(chunk)

    line, remainder = bytes(message).split(b"\n", 1)
    if remainder:
        raise RuntimeError("client sent data after the first JSON line")

    request = json.loads(line)
    if request.get("request_id") != 1:
        raise RuntimeError("client did not use request_id 1")
    command = request.get("command")
    if not isinstance(command, list) or len(command) != 2 or command[0] != "test":
        raise RuntimeError("unexpected test command")
    return command[1]


def respond(connection, scenario):
    reply = {"request_id": 1, "error": "success", "data": scenario}

    if scenario == "success":
        send_json(connection, reply)
    elif scenario == "fragmented":
        encoded = json.dumps(reply, separators=(",", ":")).encode() + b"\n"
        midpoint = len(encoded) // 2
        connection.sendall(encoded[:midpoint])
        time.sleep(0.02)
        connection.sendall(encoded[midpoint:])
    elif scenario == "multiple":
        event = json.dumps({"event": "start-file"}, separators=(",", ":")).encode()
        encoded = json.dumps(reply, separators=(",", ":")).encode()
        connection.sendall(event + b"\n" + encoded + b"\n")
    elif scenario == "event":
        send_json(connection, {"event": "property-change", "data": True})
        send_json(connection, reply)
    elif scenario == "unrelated":
        send_json(connection, {"request_id": 99, "error": "success", "data": "wrong"})
        send_json(connection, reply)
    elif scenario == "mpv_error":
        send_json(connection, {"request_id": 1, "error": "property unavailable"})
    elif scenario == "server_disappears":
        return
    elif scenario == "malformed":
        connection.sendall(b"{not-json}\n")
    elif scenario == "malformed_reply":
        send_json(connection, {"request_id": 1, "data": "missing error field"})
    elif scenario == "timeout":
        time.sleep(0.15)
        try:
            send_json(connection, reply)
        except BrokenPipeError:
            pass
    elif scenario.startswith("repeat-"):
        send_json(connection, reply)
    else:
        raise RuntimeError(f"unknown scenario: {scenario}")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} SOCKET")

    connection_count = int(os.environ.get("FAKE_MPV_CONNECTIONS", "10"))

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(sys.argv[1])
        server.listen()

        for _ in range(connection_count):
            connection, _ = server.accept()
            with connection:
                respond(connection, receive_request(connection))


if __name__ == "__main__":
    main()
