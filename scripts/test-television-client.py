#!/usr/bin/env python3
"""Exercise the real CLI against a loopback-only TV fixture; never contacts a TV."""
import argparse
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time


def read_exact(connection, count):
    data = b""
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise AssertionError("client truncated a frame")
        data += part
    return data


def read_key(connection):
    kind, length = struct.unpack(">BH", read_exact(connection, 3))
    assert kind == 4 and length == 65
    code, message_id, data_length = struct.unpack(">BIH", read_exact(connection, 7))
    assert code == 1 and data_length == 58
    payload = read_exact(connection, data_length)
    fields, offset = {}, 0
    while offset < len(payload):
        tag = payload[offset]
        width = 8 if tag in (7, 8) else 4
        assert tag in (1, 2, 3, 4, 5, 6, 7, 8, 10, 11) and tag not in fields
        fields[tag] = int.from_bytes(payload[offset + 1:offset + 1 + width], "big", signed=True)
        offset += width + 1
    assert offset == 58 and fields[7] == fields[8] == 0
    assert fields[1] == fields[4] == fields[5] == fields[6] == 0
    assert fields[10] == -1 and fields[11] == 0x101
    return message_id, fields


def ack(message_id):
    return struct.pack(">BHBIH", 4, 7, 2, message_id, 0)


def scenario(binary, root, base_config, verb, expected_key=None, partial=False, generic=False):
    failures = []
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        listener.settimeout(8)
        port = listener.getsockname()[1]
        config = dict(base_config, television={"enabled": True, "host": "127.0.0.1", "port": port})
        config_path = root / "fixture-config.json"
        config_path.write_text(json.dumps(config))

        def serve():
            try:
                with listener.accept()[0] as connection:
                    connection.settimeout(5)
                    if expected_key is None:
                        assert connection.recv(1) == b"", "status sent a key"
                        return
                    first_id, down = read_key(connection)
                    second_id, up = read_key(connection)
                    assert first_id != second_id
                    assert down[2] == 0 and up[2] == 1
                    assert down[3] == up[3] == expected_key
                    # An unrelated response must not complete the request. Valid ACKs
                    # arrive in reverse order, split across separate TCP writes.
                    reply = ack(second_id + 123) + ack(second_id)
                    connection.sendall(reply[:2])
                    time.sleep(0.03)
                    connection.sendall(reply[2:])
                    time.sleep(0.08)
                    if not partial:
                        connection.sendall(ack(first_id))
                        assert connection.recv(1) == b"", "unexpected retry/data after pair"
                listener.settimeout(0.15)
                try:
                    extra, _ = listener.accept()
                    extra.close()
                    raise AssertionError("client retried an ambiguous command")
                except TimeoutError:
                    pass
            except Exception as error:
                failures.append(repr(error))

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        if generic:
            args = [str(binary), "--config", str(config_path), "--run-action",
                    json.dumps({"type": "system", "value": "tv_volume_down"})]
        else:
            args = [str(binary), "--tv", verb, "--config", str(config_path)]
        result = subprocess.run(args, capture_output=True, text=True, timeout=9)
        worker.join(timeout=8)
        assert not worker.is_alive() and not failures, failures
        assert (result.returncode != 0) if partial else (result.returncode == 0), result.stdout + result.stderr
        print(f"PASS {verb}{' partial ACK' if partial else ''}{' generic action' if generic else ''}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("/Applications/MiRemote.app/Contents/MacOS/miremote"))
    args = parser.parse_args()
    base_config = json.loads(subprocess.check_output([str(args.binary), "--print-default-config"], text=True))
    with tempfile.TemporaryDirectory(prefix="miremote-tv-fixture-") as directory:
        root = Path(directory)
        scenario(args.binary, root, base_config, "status")
        scenario(args.binary, root, base_config, "volume-down", 25)
        scenario(args.binary, root, base_config, "standby", 223)
        scenario(args.binary, root, base_config, "wake", 224)
        scenario(args.binary, root, base_config, "volume-down", 25, partial=True)
        scenario(args.binary, root, base_config, "volume-down", 25, generic=True)
        rejected = subprocess.run([str(args.binary), "--tv", "off"], capture_output=True, text=True, timeout=3)
        assert rejected.returncode != 0 and "尚未接入" in rejected.stdout
        print("PASS true shutdown is not aliased to standby")


if __name__ == "__main__":
    main()
