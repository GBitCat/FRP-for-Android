import 'dart:async';
import 'dart:io';

enum StunProbeStatus { reachable, timeout, error }

class StunProbeResult {
  const StunProbeResult(this.status, {this.exitCode, this.detail = ''});

  final StunProbeStatus status;
  final int? exitCode;
  final String detail;

  factory StunProbeResult.fromMap(Map<Object?, Object?> value) {
    final exitCode = value['exitCode'] as int?;
    final status = switch (value['status']) {
      'reachable' when exitCode == 0 => StunProbeStatus.reachable,
      'timeout' => StunProbeStatus.timeout,
      _ => StunProbeStatus.error,
    };
    return StunProbeResult(
      status,
      exitCode: exitCode,
      detail: value['detail'] as String? ?? '',
    );
  }
}

class StunCandidate {
  const StunCandidate({required this.endpoint, required this.result});

  final String endpoint;
  final StunProbeResult result;
  int get weight => result.status == StunProbeStatus.reachable ? 1 : 0;
}

class StunSelectionException implements Exception {
  const StunSelectionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The current frpc STUN implementation uses udp4 and accepts one endpoint.
/// Probe every DNS candidate sequentially, then rotate only through successes.
class StunServerSelector {
  StunServerSelector({
    required this.probe,
    Future<List<InternetAddress>> Function(String)? lookup,
    DateTime Function()? clock,
    this.host = 'stun.easyvoip.com',
    this.port = 3478,
    this.cacheDuration = const Duration(minutes: 5),
    this.lookupTimeout = const Duration(seconds: 5),
  }) : lookup = lookup ?? _lookupIPv4,
       clock = clock ?? DateTime.now;

  final Future<StunProbeResult> Function(String endpoint) probe;
  final Future<List<InternetAddress>> Function(String host) lookup;
  final DateTime Function() clock;
  final String host;
  final int port;
  final Duration cacheDuration;
  final Duration lookupTimeout;
  List<StunCandidate> _candidates = const [];
  List<StunCandidate> get candidates => _candidates;
  DateTime? _checkedAt;
  Future<void>? _preparing;
  int _next = 0;
  bool _disposed = false;
  String? _error;

  static Future<List<InternetAddress>> _lookupIPv4(String host) =>
      InternetAddress.lookup(host, type: InternetAddressType.IPv4);

  Future<void> prepare({bool force = false}) {
    if (_disposed) return Future.value();
    final active = _preparing;
    if (active != null) return active;
    final checkedAt = _checkedAt;
    if (!force &&
        checkedAt != null &&
        clock().difference(checkedAt) < cacheDuration) {
      return Future.value();
    }
    return _preparing = _scan().whenComplete(() => _preparing = null);
  }

  Future<void> _scan() async {
    final checked = <StunCandidate>[];
    _error = null;
    try {
      final addresses = await lookup(host).timeout(lookupTimeout);
      final endpoints = {
        for (final address in addresses)
          if (address.type == InternetAddressType.IPv4)
            '${address.address}:$port',
      };
      if (endpoints.isEmpty) {
        _error = 'No IPv4 addresses were found for the STUN server.';
      }
      for (final endpoint in endpoints) {
        if (_disposed) return;
        StunProbeResult result;
        try {
          // The Android worker owns the subprocess deadline and cleanup.
          result = await probe(endpoint);
        } catch (_) {
          result = const StunProbeResult(
            StunProbeStatus.error,
            detail: 'Unable to run the STUN probe.',
          );
        }
        if (_disposed) return;
        checked.add(StunCandidate(endpoint: endpoint, result: result));
      }
    } on TimeoutException {
      _error = 'STUN DNS lookup timed out. Try starting again.';
    } catch (_) {
      _error =
          'Unable to resolve the STUN server. Check the network and try again.';
    }
    if (_disposed) return;
    _candidates = List.unmodifiable(checked);
    _checkedAt = clock();
    _next = 0;
  }

  Future<void> prepareForSelection() async {
    // An explicit start after a failed scan should retry instead of pinning a
    // transient outage for the entire cache interval.
    await prepare(
      force: _checkedAt != null && !_candidates.any((c) => c.weight == 1),
    );
  }

  Future<String> nextEndpoint() async {
    await prepareForSelection();
    return takeNextEndpoint();
  }

  /// Consume only after the caller has checked that its start is still current.
  String takeNextEndpoint() {
    if (_disposed) {
      throw const StunSelectionException('STUN selection was cancelled.');
    }
    final available = _candidates.where((c) => c.weight == 1).toList();
    if (available.isEmpty) {
      throw StunSelectionException(
        _error ?? 'No STUN address passed the frpc probe. Check the network and try starting again.',
      );
    }
    final endpoint = available[_next % available.length].endpoint;
    _next = (_next + 1) % available.length;
    return endpoint;
  }

  void dispose() => _disposed = true;
}
