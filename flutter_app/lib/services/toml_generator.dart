import '../models/frp_config.dart';
import '../models/server_config.dart';

String _tomlString(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');

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
      if (c.useFallback && c.fallbackTo.isNotEmpty) {
        b.writeln('fallbackTo = "${_tomlString(c.fallbackTo)}"');
        b.writeln('fallbackTimeoutMs = ${c.fallbackTimeoutMs}');
      }
    }
  } else if (c.needsSecretKey()) {
    b.writeln('[[proxies]]');
    b.writeln('name = "${_tomlString(c.name)}"');
    b.writeln('type = "${c.protocol}"');
    b.writeln('localIP = "${_tomlString(c.localIp)}"');
    b.writeln('localPort = ${c.localPort}');
    if ((c.secretKey ?? '').isNotEmpty) {
      b.writeln('secretKey = "${_tomlString(c.secretKey!)}"');
    }
  } else {
    b.writeln('[[proxies]]');
    b.writeln('name = "${_tomlString(c.name)}"');
    b.writeln('type = "${c.protocol}"');
    b.writeln('localIP = "${_tomlString(c.localIp)}"');
    b.writeln('localPort = ${c.localPort}');
    if (c.remotePort > 0) b.writeln('remotePort = ${c.remotePort}');
  }
  if (c.useEncryption || c.useCompression) {
    b.writeln();
    b.writeln(
      c.isVisitor() && c.needsSecretKey()
          ? '[visitors.transport]'
          : '[proxies.transport]',
    );
    b.writeln('useEncryption = ${c.useEncryption}');
    b.writeln('useCompression = ${c.useCompression}');
  }
  return b.toString();
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
    b.writeln('# Fallback STCP visitor');
    b.write(configBlock(linkedConfig));
    b.writeln();
    b.writeln('# Primary XTCP visitor');
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
