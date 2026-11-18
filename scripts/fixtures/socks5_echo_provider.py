"""Local provider for FrpcEndpointAuthIntegrationTest's TCP/UDP echo test."""

import argparse
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path


class TcpEcho(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(8192):
            self.request.sendall(data)


class UdpEcho(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frpc", type=Path)
    parser.add_argument("frps_port", type=int)
    args = parser.parse_args()
    config = f'''serverAddr = "127.0.0.1"
serverPort = {args.frps_port}
transport.wireProtocol = "v2"
natHoleStunServer = "127.0.0.1:9"
log.disablePrintColor = true
'''
    for protocol, plugin in (("stcp", "socks5"), ("sudp", "socks5_udp")):
        config += f'''
[[proxies]]
name = "audit-echo-{protocol}"
type = "{protocol}"
secretKey = "audit-fixture"
[proxies.plugin]
type = "{plugin}"
username = "test-user"
password = "test-password"
'''
        if protocol == "sudp":
            config += 'sessionMode = "datagram"\n'

    address = ("127.0.0.1", 27981)
    with (
        socketserver.ThreadingTCPServer(address, TcpEcho) as tcp,
        socketserver.UDPServer(address, UdpEcho) as udp,
        tempfile.TemporaryDirectory() as work,
    ):
        tcp.daemon_threads = True
        for server in (tcp, udp):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        path = Path(work) / "provider.toml"
        path.write_text(config, encoding="utf-8")
        subprocess.run([str(args.frpc.resolve()), "-c", str(path)], check=True)


if __name__ == "__main__":
    main()
