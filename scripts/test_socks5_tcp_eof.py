#!/usr/bin/env python3
"""Check response/EOF delivery with isolated loopback frps/frpc processes.

Keep --frpc and --frps unchanged between runs and replace --provider-frpc
to isolate the SOCKS5 plugin fix. No application configuration is accessed.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import threading
import time


SMALL_REQUEST = b'Q' * 120
SMALL_RESPONSE = b'R' * 52
LARGE_REQUEST = b'L' * 120
LARGE_RESPONSE = bytes(range(256)) * 1024
RTSP_REQUEST = b'OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n'
RTSP_RESPONSE = b'RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n'


def read_exact(conn, size):
    data = bytearray()
    while len(data) < size:
        part = conn.recv(size - len(data))
        if not part:
            raise EOFError(f'Expected {size} bytes, received {len(data)}')
        data.extend(part)
    return bytes(data)


class Target:
    """Response-then-close endpoint plus a persistent sibling connection."""

    def __init__(self):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.listener.settimeout(0.2)
        self.port = self.listener.getsockname()[1]
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.clients = set()
        self.errors = []
        self.workers = []
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self.lock:
                self.clients.add(conn)
            worker = threading.Thread(target=self.handle, args=(conn,))
            self.workers.append(worker)
            worker.start()

    def handle(self, conn):
        try:
            with conn:
                conn.settimeout(30)
                first = read_exact(conn, 4)
                if first == b'PING':
                    conn.sendall(b'PONG')
                    while True:
                        data = conn.recv(4)
                        if not data:
                            return
                        data += read_exact(conn, 4 - len(data))
                        if data != b'PING':
                            raise AssertionError('Unexpected sibling request')
                        conn.sendall(b'PONG')
                elif first == b'OPTI':
                    data = first
                    while not data.endswith(b'\r\n\r\n') and len(data) < 4096:
                        data += read_exact(conn, 1)
                    if data != RTSP_REQUEST:
                        raise AssertionError('Unexpected RTSP request')
                    conn.sendall(RTSP_RESPONSE)
                else:
                    data = first + read_exact(conn, 116)
                    if data == SMALL_REQUEST:
                        conn.sendall(SMALL_RESPONSE)
                    elif data == LARGE_REQUEST:
                        conn.sendall(LARGE_RESPONSE)
                    else:
                        raise AssertionError('Unexpected test request')
                conn.shutdown(socket.SHUT_RDWR)
        except Exception as error:
            if not self.stopped.is_set():
                with self.lock:
                    self.errors.append(str(error))
        finally:
            with self.lock:
                self.clients.discard(conn)

    def close(self):
        self.stopped.set()
        self.listener.close()
        self.thread.join(2)
        with self.lock:
            clients = list(self.clients)
        for conn in clients:
            with contextlib.suppress(OSError):
                conn.shutdown(socket.SHUT_RDWR)
            conn.close()
        for worker in self.workers:
            worker.join(2)


def reserve_ports(stack, count):
    sockets = [stack.enter_context(socket.socket()) for _ in range(count)]
    for conn in sockets:
        conn.bind(('127.0.0.1', 0))
    return sockets, [conn.getsockname()[1] for conn in sockets]


@contextlib.contextmanager
def running_frp(args, target_port):
    processes = []
    with tempfile.TemporaryDirectory(prefix='frpc-eof-check-') as temp, contextlib.ExitStack() as stack:
        private = Path(temp)
        reserved, (server_port, plain_port, socks_port) = reserve_ports(stack, 3)
        token, key = secrets.token_hex(16), secrets.token_hex(16)
        common = f'''serverAddr = "127.0.0.1"
serverPort = {server_port}
auth.token = "{token}"
transport.wireProtocol = "{args.wire_protocol}"
transport.tcpMux = true
loginFailExit = false
log.level = "info"
log.disablePrintColor = true
'''
        stream = f'''transport.useEncryption = {str(args.encryption).lower()}
transport.useCompression = {str(args.compression).lower()}
'''
        configs = {
            'server': f'bindAddr = "127.0.0.1"\nbindPort = {server_port}\nauth.token = "{token}"\nlog.level = "info"\n',
            'provider': common + f'''
[[proxies]]
name = "eof_plain"
type = "stcp"
secretKey = "{key}"
localIP = "127.0.0.1"
localPort = {target_port}
{stream}
[[proxies]]
name = "eof_socks"
type = "stcp"
secretKey = "{key}"
{stream}
[proxies.plugin]
type = "socks5"
''',
            'visitor': common + f'''
[[visitors]]
name = "plain_visitor"
type = "stcp"
serverName = "eof_plain"
secretKey = "{key}"
bindAddr = "127.0.0.1"
bindPort = {plain_port}
{stream}
[[visitors]]
name = "socks_visitor"
type = "stcp"
serverName = "eof_socks"
secretKey = "{key}"
bindAddr = "127.0.0.1"
bindPort = {socks_port}
{stream}
''',
        }
        binaries = {'server': args.frps, 'provider': args.provider_frpc, 'visitor': args.frpc}
        markers = {'server': 'frps started successfully', 'provider': '[eof_socks] start proxy success', 'visitor': 'visitor added:'}
        env = {k: v for k, v in os.environ.items() if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
        try:
            for name, config in configs.items():
                path = private / (name + '.toml')
                if name != 'server':
                    config = 'clientID = "eof-check-' + name + '"\n' + config
                path.write_text(config)
                path.chmod(0o600)
                log_path = private / (name + '.log')
                log = stack.enter_context(log_path.open('wb'))
                if name == 'server':
                    reserved[0].close()
                if name == 'visitor':
                    reserved[1].close()
                    reserved[2].close()
                proc = subprocess.Popen([str(binaries[name]), '-c', str(path)], stdout=log, stderr=log, env=env)
                processes.append(proc)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and proc.poll() is None:
                    if markers[name] in log_path.read_text(errors='replace'):
                        break
                    time.sleep(0.05)
                else:
                    detail = '\n'.join(p.name + ': ' + p.read_text(errors='replace') for p in private.glob('*.log'))
                    raise RuntimeError(name + ' not ready: ' + detail.replace(token, '[redacted]').replace(key, '[redacted]')[-4000:])
            yield plain_port, socks_port
        finally:
            for proc in reversed(processes):
                proc.terminate()
            for proc in processes:
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)


def connect(port, target_port=None):
    conn = socket.create_connection(('127.0.0.1', port), timeout=5)
    try:
        if target_port is not None:
            conn.sendall(b'\x05\x01\x00')
            if read_exact(conn, 2) != b'\x05\x00':
                raise AssertionError('SOCKS authentication failed')
            conn.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', target_port))
            if read_exact(conn, 4) != b'\x05\x00\x00\x01':
                raise AssertionError('SOCKS CONNECT failed')
            read_exact(conn, 6)
        return conn
    except BaseException:
        conn.close()
        raise


def exchange(conn, request, expected, timeout):
    conn.sendall(request)
    actual = read_exact(conn, len(expected))
    if actual != expected:
        raise AssertionError('Response was corrupted')
    start = time.monotonic()
    conn.settimeout(timeout)
    try:
        if conn.recv(1) != b'':
            raise AssertionError('Unexpected data after response')
        state = 'eof'
    except socket.timeout:
        state = 'timeout_waiting_for_eof'
    return {'sentBytes': len(request), 'receivedBytes': len(actual), 'responseMatches': True,
            'afterResponse': state, 'eofWaitMs': round((time.monotonic() - start) * 1000)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('frps', 'frpc', 'provider-frpc', 'report'):
        parser.add_argument('--' + option, type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument('--wire-protocol', choices=['v1', 'v2'], default='v2')
    parser.add_argument('--encryption', action='store_true')
    parser.add_argument('--compression', action='store_true')
    parser.add_argument('--eof-timeout', type=float, default=2.0)
    parser.add_argument('--expect-socks-eof', choices=['yes', 'no'], required=True)
    args = parser.parse_args()
    if args.eof_timeout <= 0:
        parser.error('--eof-timeout must be positive')
    expected_socks = 'eof' if args.expect_socks_eof == 'yes' else 'timeout_waiting_for_eof'
    results = []
    target = Target()
    try:
        with running_frp(args, target.port) as (plain_port, socks_port):
            with connect(socks_port, target.port) as sibling:
                sibling.sendall(b'PING')
                if read_exact(sibling, 4) != b'PONG':
                    raise AssertionError('Sibling connection failed')
                for path, port, destination in [('direct', target.port, None), ('stcp_plain', plain_port, None), ('stcp_socks5_plugin', socks_port, target.port)]:
                    for name, request, response in [('matching_byte_counts', SMALL_REQUEST, SMALL_RESPONSE), ('large_response', LARGE_REQUEST, LARGE_RESPONSE), ('rtsp_options', RTSP_REQUEST, RTSP_RESPONSE)]:
                        with connect(port, destination) as conn:
                            result = exchange(conn, request, response, args.eof_timeout)
                        result.update(path=path, case=name)
                        expected = expected_socks if destination is not None else 'eof'
                        result['passed'] = result['afterResponse'] == expected
                        sibling.sendall(b'PING')
                        result['siblingUnaffected'] = read_exact(sibling, 4) == b'PONG'
                        results.append(result)
    finally:
        target.close()
    report = {'wireProtocol': args.wire_protocol, 'tcpMux': True, 'encryption': args.encryption, 'compression': args.compression,
              'expectedSocksEOF': args.expect_socks_eof, 'providerSHA256': hashlib.sha256(args.provider_frpc.read_bytes()).hexdigest(),
              'visitorSHA256': hashlib.sha256(args.frpc.read_bytes()).hexdigest(), 'results': results, 'targetErrors': target.errors}
    report['passed'] = not target.errors and all(r['passed'] and r['siblingUnaffected'] for r in results)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
