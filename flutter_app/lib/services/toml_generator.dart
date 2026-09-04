import '../models/frp_config.dart';
import '../models/server_config.dart';

String _tomlString(String value) {
  final escaped = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x08:
        escaped.write(r'\b');
        break;
      case 0x09:
        escaped.write(r'\t');
        break;
      case 0x0A:
        escaped.write(r'\n');
        break;
      case 0x0C:
        escaped.write(r'\f');
        break;
      case 0x0D:
        escaped.write(r'\r');
        break;
      case 0x22:
        escaped.write(r'\"');
        break;
      case 0x5C:
        escaped.write(r'\\');
        break;
      default:
        if (rune <= 0x1F || rune == 0x7F) {
          escaped
            ..write(r'\u')
            ..write(rune.toRadixString(16).toUpperCase().padLeft(4, '0'));
        } else {
          escaped.writeCharCode(rune);
        }
    }
  }
  return escaped.toString();
}

/// Quotes one value as a TOML basic string using the same escaping rules as
/// every generated frpc block.
String quotedTomlString(String value) => '"${_tomlString(value)}"';

/// 单个配置的 frpc 块（visitor/server 均按原 ConfigGenerator 输出）
String configBlock(FrpConfig c) {
  // 手动编写配置：原样输出
  if (c.manualToml != null && c.manualToml!.trim().isNotEmpty) {
    return '${c.manualToml!.trimRight()}\n';
  }
  final b = StringBuffer();
  if (c.isVisitor() && c.needsSecretKey()) {
    b.writeln('[[visitors]]');
    b.writeln('name = "${_tomlString(c.name)}"');
    b.writeln('type = "${c.protocol}"');
    b.writeln('serverName = "${_tomlString(c.serverName ?? '')}"');
    if ((c.secretKey ?? '').isNotEmpty) {
      b.writeln('secretKey = "${_tomlString(c.secretKey!)}"');
    }
    if (c.bindPort != -1) {
      b.writeln('bindAddr = "${_tomlString(c.bindAddr)}"');
    }
    b.writeln('bindPort = ${c.bindPort}');
    if (c.protocol == 'xtcp') {
      b.writeln('keepTunnelOpen = true');
    }
    if (c.supportsFallback() && c.useFallback && c.fallbackTo.isNotEmpty) {
      b.writeln('fallbackTo = "${_tomlString(c.fallbackTo)}"');
      b.writeln('fallbackTimeoutMs = ${c.fallbackTimeoutMs}');
    }
    _writeTransport(b, c, 'visitors');
  } else if (c.needsSecretKey()) {
    b.writeln('[[proxies]]');
    b.writeln('name = "${_tomlString(c.name)}"');
    b.writeln('type = "${c.protocol}"');
    b.writeln('localIP = "${_tomlString(c.localIp)}"');
    b.writeln('localPort = ${c.localPort}');
    if ((c.secretKey ?? '').isNotEmpty) {
      b.writeln('secretKey = "${_tomlString(c.secretKey!)}"');
    }
    _writeTransport(b, c, 'proxies');
  } else if (c.supportsMultiplePorts()) {
    final mappings = c.effectivePortMappings;
    for (var i = 0; i < mappings.length; i++) {
      if (i > 0) b.writeln();
      final mapping = mappings[i];
      _writeRegularProxy(
        b,
        c,
        name: c.proxyNameForMapping(mapping),
        localPort: mapping.localPort,
        remotePort: mapping.remotePort,
      );
    }
  } else {
    _writeRegularProxy(
      b,
      c,
      name: c.name,
      localPort: c.localPort,
      remotePort: c.remotePort,
    );
  }
  return b.toString();
}

void _writeRegularProxy(
  StringBuffer b,
  FrpConfig config, {
  required String name,
  required int localPort,
  required int remotePort,
}) {
  b.writeln('[[proxies]]');
  b.writeln('name = "${_tomlString(name)}"');
  b.writeln('type = "${config.protocol}"');
  b.writeln('localIP = "${_tomlString(config.localIp)}"');
  b.writeln('localPort = $localPort');
  if (config.protocol.toLowerCase() == 'http' ||
      config.protocol.toLowerCase() == 'https') {
    final domains = config.customDomains
        .map((domain) => domain.trim())
        .where((domain) => domain.isNotEmpty)
        .map((domain) => '"${_tomlString(domain)}"')
        .join(', ');
    if (domains.isNotEmpty) b.writeln('customDomains = [$domains]');
  } else if (remotePort > 0) {
    b.writeln('remotePort = $remotePort');
  }
  _writeTransport(b, config, 'proxies');
}

void _writeTransport(StringBuffer b, FrpConfig config, String table) {
  if (!config.useEncryption && !config.useCompression) return;
  b.writeln();
  b.writeln('[$table.transport]');
  b.writeln('useEncryption = ${config.useEncryption}');
  b.writeln('useCompression = ${config.useCompression}');
}

/// 全局服务器连接配置段
String globalBlock(ServerConfig server) {
  final b = StringBuffer();
  b.writeln('serverAddr = "${_tomlString(server.serverAddr)}"');
  b.writeln('serverPort = ${server.serverPort}');
  if (server.token.isNotEmpty) {
    b.writeln('auth.token = "${_tomlString(server.token)}"');
  }
  b.writeln('natHoleStunServer = "stun.easyvoip.com:3478"');
  b.writeln();
  b.writeln('transport.protocol = "${_tomlString(server.protocol)}"');
  b.writeln('transport.tcpMux = ${server.tcpMux}');
  b.writeln('transport.heartbeatInterval = ${server.heartbeatInterval}');
  b.writeln('transport.heartbeatTimeout = ${server.heartbeatTimeout}');
  b.writeln(
    'transport.tcpMuxKeepaliveInterval = ${server.tcpMuxKeepaliveInterval}',
  );
  if (server.tlsEnabled) {
    b.writeln('transport.tls.enable = true');
    b.writeln('transport.tls.certFile = "${_tomlString(server.tlsCertFile)}"');
    b.writeln('transport.tls.keyFile = "${_tomlString(server.tlsKeyFile)}"');
    b.writeln(
      'transport.tls.trustedCaFile = "${_tomlString(server.tlsTrustedCaFile)}"',
    );
    if (server.tlsServerName.isNotEmpty) {
      b.writeln(
        'transport.tls.serverName = "${_tomlString(server.tlsServerName)}"',
      );
    }
  }
  b.writeln();
  return b.toString();
}

/// 单配置完整预览（编辑页用）
String generateToml(
  ServerConfig server,
  FrpConfig config,
  FrpConfig? linkedConfig,
) {
  final b = StringBuffer();
  b.write(globalBlock(server));
  if (linkedConfig != null) {
    b.writeln('# Fallback ${linkedConfig.protocol.toUpperCase()} visitor');
    b.write(configBlock(linkedConfig));
    b.writeln();
    b.writeln('# Primary ${config.protocol.toUpperCase()} visitor');
  }
  b.write(configBlock(config));
  return b.toString();
}

/// Server 配置预览：全局段 + 隶属于该 server 的应用配置拼接
/// 每个应用块上方加 `# Config: 名称 (协议)` 注释；
/// 若块本身（如手动编写的配置）已经带有 `# Config:` 注释则不再重复添加。
String generateServerPreview(ServerConfig server, List<FrpConfig> appConfigs) {
  final b = StringBuffer();
  b.write(globalBlock(server));
  for (var i = 0; i < appConfigs.length; i++) {
    if (i > 0) b.writeln();
    final block = configBlock(appConfigs[i]).trimRight();
    final hasComment = block
        .split('\n')
        .any((line) => line.trimLeft().startsWith('# Config:'));
    if (!hasComment) {
      b.writeln('# Config: ${appConfigs[i].name} (${appConfigs[i].protocol})');
    }
    b.writeln(block);
  }
  return b.toString();
}
