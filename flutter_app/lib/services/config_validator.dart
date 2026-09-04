import '../models/frp_config.dart';

class ConfigValidator {
  const ConfigValidator._();

  static String? validate(
    FrpConfig config, {
    bool allowMissingSecrets = false,
    bool allowIncompleteLegacy = false,
  }) {
    if (config.name.trim().isEmpty) return 'Name is required';
    if (config.name.length > 128 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(config.name)) {
      return 'Name must contain at most 128 valid characters';
    }
    if (config.groupName.length > 128 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(config.groupName)) {
      return 'Group name must contain at most 128 valid characters';
    }
    for (final value in [
      config.serverName ?? '',
      config.fallbackTo,
      config.stcpName,
      config.stcpServerName,
    ]) {
      if (value.length > 128 ||
          RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
        return 'Proxy names must contain at most 128 valid characters';
      }
    }

    final protocol = config.protocol.toLowerCase();
    if (!FrpConfig.protocols.contains(protocol)) {
      return 'Unsupported proxy protocol';
    }
    if (config.role != 'server' && config.role != 'visitor') {
      return 'Role must be server or visitor';
    }
    if (config.serverId.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(config.serverId)) {
      return 'Server ID must contain exactly 8 letters or digits';
    }
    if (config.id < 0 ||
        config.groupId < 0 ||
        config.linkedConfigId < 0 ||
        config.createdAt < 0 ||
        config.updatedAt < 0) {
      return 'Configuration identifiers and timestamps must not be negative';
    }
    for (final address in [
      config.serverAddr,
      config.localIp,
      config.bindAddr,
      config.stcpBindAddr,
    ]) {
      if (address.length > 255 ||
          RegExp(r'[\u0000-\u001f\u007f]').hasMatch(address)) {
        return 'Proxy address contains invalid characters';
      }
    }
    if (config.serverPort < 1 || config.serverPort > 65535) {
      return 'Legacy server port must be between 1 and 65535';
    }
    if (config.customDomains.length > FrpConfig.maxCustomDomains ||
        config.customDomains.any(
          (domain) =>
              domain.length > 255 ||
              RegExp(r'[\u0000-\u001f\u007f]').hasMatch(domain),
        )) {
      return 'Custom domains contain invalid values';
    }
    if (config.portMappings.length > FrpConfig.maxPortMappings ||
        config.portMappings.any(
          (mapping) =>
              mapping.localPort < 0 ||
              mapping.localPort > 65535 ||
              mapping.remotePort < 0 ||
              mapping.remotePort > 65535,
        )) {
      return 'Port mappings contain invalid values';
    }
    if (config.bindPort < -1 || config.bindPort > 65535) {
      return 'Bind port must be -1 or between 1 and 65535';
    }
    if (config.stcpBindPort < -1 || config.stcpBindPort > 65535) {
      return 'Fallback bind port must be -1 or between 1 and 65535';
    }
    if (config.fallbackTimeoutMs < 0 || config.fallbackTimeoutMs > 86400000) {
      return 'Fallback timeout must be between 0 and 86400000 ms';
    }
    for (final value in [
      config.token ?? '',
      config.secretKey ?? '',
      config.stcpSecretKey,
    ]) {
      if (value.length > 16384 ||
          RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
        return 'Proxy credential is too large or contains invalid characters';
      }
    }

    if (config.manualToml case final manual?) {
      if (manual.length > 1024 * 1024 ||
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]')
              .hasMatch(manual)) {
        return 'Manual TOML is too large or contains invalid characters';
      }
      if (manual.trim().isNotEmpty) return null;
    }

    if (config.supportsMultiplePorts()) {
      final mappings = config.effectivePortMappings;
      if (mappings.length > FrpConfig.maxPortMappings) {
        return 'At most 128 port mappings are allowed';
      }
      for (final mapping in mappings) {
        if ((!allowIncompleteLegacy && mapping.localPort <= 0) ||
            mapping.localPort < 0 ||
            mapping.localPort > 65535) {
          return 'Local port must be between 1 and 65535';
        }
        if ((!allowIncompleteLegacy && mapping.remotePort <= 0) ||
            mapping.remotePort < 0 ||
            mapping.remotePort > 65535) {
          return 'Remote port must be between 1 and 65535';
        }
      }
      if (mappings.map((mapping) => mapping.localPort).toSet().length !=
          mappings.length) {
        return 'Local ports must not contain duplicates';
      }
      if (mappings.map((mapping) => mapping.remotePort).toSet().length !=
          mappings.length) {
        return 'Remote ports must not contain duplicates';
      }
      return null;
    }

    if (protocol == 'http' || protocol == 'https') {
      if ((!allowIncompleteLegacy && config.localPort <= 0) ||
          config.localPort < 0 ||
          config.localPort > 65535) {
        return 'Local port must be between 1 and 65535';
      }
      if (!allowIncompleteLegacy &&
          !config.customDomains.any((domain) => domain.trim().isNotEmpty)) {
        return 'At least one custom domain is required';
      }
      return null;
    }

    if (config.needsSecretKey()) {
      if (!allowMissingSecrets &&
          !allowIncompleteLegacy &&
          (config.secretKey ?? '').trim().isEmpty) {
        return 'Secret key is required for ${config.protocol.toUpperCase()}';
      }
      if (!allowIncompleteLegacy &&
          config.isVisitor() &&
          (config.serverName ?? '').trim().isEmpty) {
        return 'Server name is required for visitor';
      }
      if (config.isVisitor() &&
          (protocol == 'sudp' || protocol == 'xudp') &&
          ((!allowIncompleteLegacy && config.bindPort <= 0) ||
              config.bindPort < 0)) {
        return 'Bind port must be between 1 and 65535 for ${config.protocol.toUpperCase()}';
      }
      if (config.isVisitor() &&
          !allowIncompleteLegacy &&
          config.bindPort <= 0 &&
          config.bindPort != -1) {
        return 'Bind port must be -1 or between 1 and 65535';
      }
      if (!config.isVisitor() &&
          ((!allowIncompleteLegacy && config.localPort <= 0) ||
              config.localPort < 0 ||
              config.localPort > 65535)) {
        return 'Local port is required';
      }
    } else {
      if ((!allowIncompleteLegacy && config.localPort <= 0) ||
          config.localPort < 0 ||
          config.localPort > 65535) {
        return 'Local port must be between 1 and 65535';
      }
      if ((!allowIncompleteLegacy && config.remotePort <= 0) ||
          config.remotePort < 0 ||
          config.remotePort > 65535) {
        return 'Remote port must be between 1 and 65535';
      }
    }
    return null;
  }
}
