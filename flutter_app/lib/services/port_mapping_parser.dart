import '../models/frp_config.dart';

class PortMappingParseResult {
  final List<PortMapping> mappings;
  final String? error;

  const PortMappingParseResult({this.mappings = const [], this.error});

  bool get isValid => error == null;
}

class PortListParseResult {
  final List<int> ports;
  final String? error;

  const PortListParseResult({this.ports = const [], this.error});

  bool get isValid => error == null;
}

/// Parses compact port specifications such as `22,80,8000-8002` and pairs
/// the expanded local and remote values by position.
class PortMappingParser {
  const PortMappingParser._();

  static PortMappingParseResult parse(String localSpec, String remoteSpec) {
    final local = _parseSpec(localSpec, 'Local');
    if (local.error != null) {
      return PortMappingParseResult(error: local.error);
    }

    final remote = _parseSpec(remoteSpec, 'Remote');
    if (remote.error != null) {
      return PortMappingParseResult(error: remote.error);
    }

    if (local.ports.length != remote.ports.length) {
      return PortMappingParseResult(
        error:
            'Local and remote port counts must match '
            '(${local.ports.length} vs ${remote.ports.length})',
      );
    }
    if (local.ports.toSet().length != local.ports.length) {
      return const PortMappingParseResult(
        error: 'Local ports must not contain duplicates',
      );
    }
    if (remote.ports.toSet().length != remote.ports.length) {
      return const PortMappingParseResult(
        error: 'Remote ports must not contain duplicates',
      );
    }

    return PortMappingParseResult(
      mappings: [
        for (var i = 0; i < local.ports.length; i++)
          PortMapping(localPort: local.ports[i], remotePort: remote.ports[i]),
      ],
    );
  }

  /// Parses a single compact port specification such as
  /// `9002,9010-9012`. This is used by grouped visitor configurations where
  /// every selected protocol owns one bind-port input.
  static PortListParseResult parsePorts(
    String spec, {
    String label = 'Bind',
    bool allowDisabledPort = false,
  }) {
    final result = _parseSpec(
      spec,
      label,
      allowDisabledPort: allowDisabledPort,
    );
    if (result.error != null) {
      return PortListParseResult(error: result.error);
    }
    if (allowDisabledPort &&
        result.ports.length > 1 &&
        result.ports.contains(-1)) {
      return PortListParseResult(
        error: '$label disabled port -1 cannot be combined with other ports',
      );
    }
    if (result.ports.toSet().length != result.ports.length) {
      return PortListParseResult(
        error: '$label ports must not contain duplicates',
      );
    }
    return PortListParseResult(ports: result.ports);
  }

  static String formatPorts(Iterable<int> values) {
    final ports = values.toList();
    if (ports.isEmpty) return '';

    final parts = <String>[];
    var start = ports.first;
    var end = start;
    for (final port in ports.skip(1)) {
      if (port == end + 1) {
        end = port;
        continue;
      }
      parts.add(start == end ? '$start' : '$start-$end');
      start = port;
      end = port;
    }
    parts.add(start == end ? '$start' : '$start-$end');
    return parts.join(',');
  }

  static _PortSpecParseResult _parseSpec(
    String input,
    String label, {
    bool allowDisabledPort = false,
  }) {
    final normalized = input
        .trim()
        .replaceAll('，', ',')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('\n', ',');
    if (normalized.isEmpty) {
      return _PortSpecParseResult(error: '$label ports are required');
    }

    final ports = <int>[];
    for (final rawPart in normalized.split(',')) {
      final part = rawPart.trim();
      if (part.isEmpty) {
        return _PortSpecParseResult(
          error: '$label ports contain an empty item',
        );
      }

      final single = int.tryParse(part);
      if (single != null) {
        final error = _validatePort(
          single,
          label,
          allowDisabledPort: allowDisabledPort,
        );
        if (error != null) return _PortSpecParseResult(error: error);
        ports.add(single);
      } else {
        final range = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(part);
        if (range == null) {
          return _PortSpecParseResult(
            error: '$label ports contain an invalid item: "$part"',
          );
        }
        final start = int.parse(range.group(1)!);
        final end = int.parse(range.group(2)!);
        final startError = _validatePort(
          start,
          label,
          allowDisabledPort: allowDisabledPort,
        );
        if (startError != null) {
          return _PortSpecParseResult(error: startError);
        }
        final endError = _validatePort(
          end,
          label,
          allowDisabledPort: allowDisabledPort,
        );
        if (endError != null) return _PortSpecParseResult(error: endError);
        if (start > end) {
          return _PortSpecParseResult(
            error: '$label port range must be ascending: "$part"',
          );
        }
        if (ports.length + end - start + 1 > FrpConfig.maxPortMappings) {
          return const _PortSpecParseResult(
            error: 'At most 128 port mappings are allowed',
          );
        }
        for (var port = start; port <= end; port++) {
          ports.add(port);
        }
      }

      if (ports.length > FrpConfig.maxPortMappings) {
        return const _PortSpecParseResult(
          error: 'At most 128 port mappings are allowed',
        );
      }
    }
    return _PortSpecParseResult(ports: ports);
  }

  static String? _validatePort(
    int port,
    String label, {
    bool allowDisabledPort = false,
  }) {
    if (allowDisabledPort && port == -1) return null;
    if (port < 1 || port > 65535) {
      return allowDisabledPort
          ? '$label port must be -1 or between 1 and 65535'
          : '$label port must be between 1 and 65535';
    }
    return null;
  }
}

class _PortSpecParseResult {
  final List<int> ports;
  final String? error;

  const _PortSpecParseResult({this.ports = const [], this.error});
}
