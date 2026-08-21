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
    expect(toml, contains('localPort = 22'));
    expect(toml, contains('remotePort = 10022'));
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

  test('manual TOML is preserved without generated fields', () {
    const manual = '[[visitors]]\nname = "manual"\ntype = "stcp"\n';
    expect(configBlock(const FrpConfig(manualToml: manual)), manual);
  });
}
