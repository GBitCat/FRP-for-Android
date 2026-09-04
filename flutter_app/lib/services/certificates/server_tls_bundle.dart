import 'dart:convert';
import 'dart:typed_data';

import '../wipeable_zip_builder.dart';

/// Builds the plaintext ZIP that is encrypted as an exported `.frptls` file.
///
/// The server certificate issuer and the roots trusted for client
/// authentication are intentionally separate inputs. They are the same only
/// when the user explicitly selects a same-CA deployment.
///
/// The returned buffer contains the plaintext server private key and must be
/// overwritten by the caller immediately after encryption or on failure.
abstract final class ServerTlsBundle {
  static const _maxPlaintextBytes = 5 * 1024 * 1024;
  static const maxTrustedClientCACertificates = 64;
  static const maxTrustedClientCABundleBytes = 2 * 1024 * 1024;

  static Uint8List build({
    required List<int> serverCertificate,
    required List<int> serverPrivateKey,
    required List<int> serverSigningCA,
    required Iterable<List<int>> trustedClientCAs,
  }) {
    if (serverCertificate.isEmpty ||
        serverPrivateKey.isEmpty ||
        serverSigningCA.isEmpty) {
      throw const FormatException('Server certificate bundle is incomplete');
    }
    final trustedClientCABundle = mergeCABundles(trustedClientCAs);
    final config = utf8.encode(
      'transport.tls.force = true\n'
      'transport.tls.certFile = "/etc/frp/tls/server.crt"\n'
      'transport.tls.keyFile = "/etc/frp/tls/server.key"\n'
      'transport.tls.trustedCaFile = '
      '"/etc/frp/tls/trusted-client-ca.crt"\n',
    );
    final readme = utf8.encode(
      'server.crt: frps server certificate\n'
      'server.key: frps server private key (keep mode 0600)\n'
      'server-ca.crt: CA that clients use to verify server.crt\n'
      'trusted-client-ca.crt: CA bundle frps uses to verify client certificates\n'
      'frps-tls.toml: TLS settings to merge into frps.toml\n',
    );
    return WipeableStoredZipBuilder.build([
      WipeableZipEntry('server.crt', serverCertificate),
      WipeableZipEntry('server.key', serverPrivateKey),
      WipeableZipEntry('server-ca.crt', serverSigningCA),
      WipeableZipEntry('trusted-client-ca.crt', trustedClientCABundle),
      WipeableZipEntry('frps-tls.toml', config),
      WipeableZipEntry('README.txt', readme),
    ], maxOutputBytes: _maxPlaintextBytes);
  }

  static Uint8List mergeCABundles(Iterable<List<int>> bundles) {
    final certificates = <String>{};
    var processedCertificates = 0;
    var processedBytes = 0;
    for (final bundle in bundles) {
      if (bundle.isEmpty) continue;
      processedBytes += bundle.length;
      if (processedBytes > maxTrustedClientCABundleBytes) {
        throw const FormatException(
          'Trusted client CA bundle exceeds the size limit',
        );
      }
      final text = utf8.decode(bundle).replaceAll('\r\n', '\n');
      var foundCertificate = false;
      var cursor = 0;
      // RegExp.allMatches is lazy. Stop at the same bounded certificate count
      // accepted by the native certificate layer instead of materializing an
      // attacker-controlled match list before checking its size.
      for (final match in _certificatePattern.allMatches(text)) {
        foundCertificate = true;
        processedCertificates++;
        if (processedCertificates > maxTrustedClientCACertificates) {
          throw const FormatException(
            'Trusted client CA bundle contains too many certificates',
          );
        }
        if (text.substring(cursor, match.start).trim().isNotEmpty) {
          throw const FormatException(
            'Trusted client CA file contains unsupported content',
          );
        }
        final body = match.group(1)!.replaceAll(RegExp(r'\s'), '');
        try {
          if (base64Decode(body).isEmpty) {
            throw const FormatException();
          }
        } on FormatException {
          throw const FormatException(
            'Trusted client CA file contains invalid PEM data',
          );
        }
        certificates.add(
          '-----BEGIN CERTIFICATE-----\n'
          '${_wrapBase64(body)}\n'
          '-----END CERTIFICATE-----',
        );
        cursor = match.end;
      }
      if (!foundCertificate) {
        throw const FormatException(
          'Trusted client CA file contains no PEM certificate',
        );
      }
      if (text.substring(cursor).trim().isNotEmpty) {
        throw const FormatException(
          'Trusted client CA file contains unsupported content',
        );
      }
    }
    if (certificates.isEmpty) {
      throw const FormatException('Select at least one trusted client CA');
    }
    return Uint8List.fromList(utf8.encode('${certificates.join('\n')}\n'));
  }

  static String _wrapBase64(String value) {
    final lines = <String>[];
    for (var offset = 0; offset < value.length; offset += 64) {
      final end = offset + 64 < value.length ? offset + 64 : value.length;
      lines.add(value.substring(offset, end));
    }
    return lines.join('\n');
  }

  static final RegExp _certificatePattern = RegExp(
    r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----',
  );
}
