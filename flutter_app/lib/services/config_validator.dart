import '../models/frp_config.dart';

class ConfigValidator {
  const ConfigValidator._();

  static String? validate(FrpConfig config) {
    if (config.name.trim().isEmpty) return 'Name is required';
    if (config.needsSecretKey()) {
      if (config.isVisitor() && (config.serverName ?? '').trim().isEmpty) {
        return 'Server name is required for visitor';
      }
      if (config.isVisitor() && config.bindPort <= 0 && config.bindPort != -1) {
        return 'Bind port must be -1 or between 1 and 65535';
      }
      if (!config.isVisitor() && config.localPort <= 0) {
        return 'Local port is required';
      }
    } else {
      if (config.localPort <= 0 || config.localPort > 65535) {
        return 'Local port must be between 1 and 65535';
      }
      if (config.remotePort <= 0 || config.remotePort > 65535) {
        return 'Remote port must be between 1 and 65535';
      }
    }
    if (config.bindPort > 65535) return 'Bind port must not exceed 65535';
    if (config.fallbackTimeoutMs < 0) {
      return 'Fallback timeout must not be negative';
    }
    return null;
  }
}
