import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/toml_generator.dart';

void main() {
  const server = ServerConfig(
    serverId: 'SERVER01',
    serverAddr: 'frps.example.com',
    serverPort: 7000,
    token: 'quote"slash\\line\nnext',
  );

  test('global TOML escapes sensitive strings', () {
    final toml = globalBlock(server);
    expect(toml, contains('serverAddr = "frps.example.com"'));
    expect(toml, contains(r'auth.token = "quote\"slash\\line\nnext"'));
    expect(toml, contains('transport.tcpMux = true'));
    expect(toml, isNot(contains('transport.tls.certFile')));
  });

  test('TOML basic strings escape every forbidden control character', () {
    const controlServer = ServerConfig(
      serverId: 'SERVER01',
      token: 'a\b\t\f\u0001\u007f',
    );

    expect(
      globalBlock(controlServer),
      contains(r'auth.token = "a\b\t\f\u0001\u007F"'),
    );
  });

  test('global TOML emits bidirectional TLS verification settings', () {
    const tlsServer = ServerConfig(
      serverAddr: 'frps.example.com',
      tlsEnabled: true,
      tlsServerName: 'secure.example.com',
      tlsCertFile: '/data/client.crt',
      tlsKeyFile: '/data/client.key',
      tlsTrustedCaFile: '/data/ca.crt',
    );

    final toml = globalBlock(tlsServer);
    expect(toml, contains('transport.tls.enable = true'));
    expect(toml, contains('transport.tls.certFile = "/data/client.crt"'));
    expect(toml, contains('transport.tls.keyFile = "/data/client.key"'));
    expect(toml, contains('transport.tls.trustedCaFile = "/data/ca.crt"'));
    expect(toml, contains('transport.tls.serverName = "secure.example.com"'));
  });

  test('TCP proxy emits local and remote ports', () {
    const config = FrpConfig(
      name: 'ssh',
      protocol: 'tcp',
      localPort: 22,
      remotePort: 10022,
    );
    final toml = configBlock(config);
    expect(toml, contains('[[proxies]]'));
    expect(toml, contains('name = "ssh"'));
    expect(toml, contains('localPort = 22'));
    expect(toml, contains('remotePort = 10022'));
  });

  test('TCP multi-port config expands into independently named proxies', () {
    const config = FrpConfig(
      name: 'services',
      protocol: 'tcp',
      localPort: 22,
      remotePort: 10022,
      portMappings: [
        PortMapping(localPort: 22, remotePort: 10022),
        PortMapping(localPort: 8000, remotePort: 9000),
        PortMapping(localPort: 8001, remotePort: 9001),
      ],
      useEncryption: true,
    );

    final toml = configBlock(config);
    expect(
      RegExp(r'^\[\[proxies\]\]$', multiLine: true).allMatches(toml),
      hasLength(3),
    );
    expect(toml, contains('name = "services-22"'));
    expect(toml, contains('name = "services-8000"'));
    expect(toml, contains('name = "services-8001"'));
    expect(toml, contains('localPort = 8001'));
    expect(toml, contains('remotePort = 9001'));
    expect(
      RegExp(r'^\[proxies\.transport\]$', multiLine: true).allMatches(toml),
      hasLength(3),
    );
  });

  test('HTTP proxy emits custom domains instead of a remote port', () {
    const config = FrpConfig(
      name: 'web',
      protocol: 'http',
      localPort: 8080,
      remotePort: 10080,
      customDomains: ['web.example.com', 'api.example.com'],
    );
    final toml = configBlock(config);
    expect(toml, contains('localPort = 8080'));
    expect(
      toml,
      contains('customDomains = ["web.example.com", "api.example.com"]'),
    );
    expect(toml, isNot(contains('remotePort')));
  });

  test('XTCP visitor emits fallback and transport settings', () {
    const config = FrpConfig(
      name: 'ssh-xtcp',
      protocol: 'xtcp',
      role: 'visitor',
      serverName: 'ssh-xtcp',
      secretKey: 'secret',
      bindPort: -1,
      useFallback: true,
      fallbackTo: 'ssh-stcp',
      fallbackTimeoutMs: 3000,
      useEncryption: true,
    );
    final toml = configBlock(config);
    expect(toml, contains('[[visitors]]'));
    expect(toml, isNot(contains('bindAddr')));
    expect(toml, contains('fallbackTo = "ssh-stcp"'));
    expect(toml, contains('[visitors.transport]'));
  });

  test('XUDP proxy and visitor use the fork configuration schema', () {
    const proxy = FrpConfig(
      name: 'game',
      protocol: 'xudp',
      role: 'server',
      localIp: '127.0.0.1',
      localPort: 2000,
      secretKey: 'secret',
    );
    const visitor = FrpConfig(
      name: 'game-visitor',
      protocol: 'xudp',
      role: 'visitor',
      serverName: 'game',
      bindAddr: '127.0.0.1',
      bindPort: 2000,
      secretKey: 'secret',
    );
    expect(configBlock(proxy), contains('type = "xudp"'));
    expect(configBlock(proxy), contains('localPort = 2000'));
    expect(configBlock(proxy), isNot(contains('remotePort')));
    expect(configBlock(visitor), contains('[[visitors]]'));
    expect(configBlock(visitor), contains('serverName = "game"'));
    expect(configBlock(visitor), contains('bindPort = 2000'));
  });

  test('XUDP visitor emits SUDP fallback settings', () {
    const visitor = FrpConfig(
      name: 'game-xudp',
      protocol: 'xudp',
      role: 'visitor',
      serverName: 'game-xudp',
      bindPort: 2000,
      secretKey: 'secret',
      useFallback: true,
      fallbackTo: 'game-sudp',
      fallbackTimeoutMs: 2500,
    );

    final toml = configBlock(visitor);
    expect(toml, contains('fallbackTo = "game-sudp"'));
    expect(toml, contains('fallbackTimeoutMs = 2500'));
    expect(toml, isNot(contains('keepTunnelOpen')));
  });

  test('manual TOML is preserved without generated fields', () {
    const manual = '[[visitors]]\nname = "manual"\ntype = "stcp"\n';
    expect(configBlock(const FrpConfig(manualToml: manual)), manual);
  });
}
