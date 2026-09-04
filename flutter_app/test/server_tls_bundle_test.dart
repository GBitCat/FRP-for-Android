import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/certificates/server_tls_bundle.dart';

void main() {
  test('frps bundle keeps server issuer and trusted client roots separate', () {
    final zip = ServerTlsBundle.build(
      serverCertificate: utf8.encode('server certificate'),
      serverPrivateKey: utf8.encode('server private key'),
      serverSigningCA: utf8.encode('server signing CA'),
      trustedClientCAs: [
        utf8.encode(_clientCAOne),
        utf8.encode('$_clientCATwo\n$_clientCAOne'),
      ],
    );
    final archive = ZipDecoder().decodeBytes(zip);
    expect(
      archive.files.where((file) => file.isFile),
      everyElement(
        predicate<ArchiveFile>(
          (file) => file.compression == CompressionType.none,
          'is stored without compression',
        ),
      ),
    );
    final files = <String, String>{
      for (final file in archive.files)
        if (file.isFile) file.name: utf8.decode(file.content as List<int>),
    };

    expect(
      files.keys,
      containsAll([
        'server.crt',
        'server.key',
        'server-ca.crt',
        'trusted-client-ca.crt',
        'frps-tls.toml',
        'README.txt',
      ]),
    );
    expect(files, isNot(contains('ca.crt')));
    expect(files['server-ca.crt'], 'server signing CA');
    expect(
      RegExp('BEGIN CERTIFICATE')
          .allMatches(files['trusted-client-ca.crt']!)
          .length,
      2,
    );
    expect(
      files['frps-tls.toml'],
      contains(
        'transport.tls.trustedCaFile = '
        '"/etc/frp/tls/trusted-client-ca.crt"',
      ),
    );
    expect(files['frps-tls.toml'], isNot(contains('/ca.crt')));
  });

  test('trusted client CA bundle must contain only PEM certificates', () {
    expect(
      () => ServerTlsBundle.mergeCABundles([utf8.encode('not a certificate')]),
      throwsFormatException,
    );
    expect(
      () => ServerTlsBundle.mergeCABundles([
        utf8.encode('unexpected\n$_clientCAOne'),
      ]),
      throwsFormatException,
    );
    expect(
      () => ServerTlsBundle.mergeCABundles(const []),
      throwsFormatException,
    );
  });

  test('trusted client CA parsing stops at the native certificate limit', () {
    final oversized = List<String>.filled(
      ServerTlsBundle.maxTrustedClientCACertificates + 1,
      _clientCAOne,
    ).join('\n');

    expect(
      () => ServerTlsBundle.mergeCABundles([utf8.encode(oversized)]),
      throwsFormatException,
    );
  });

  test('trusted client CA input has an aggregate byte limit', () {
    expect(
      () => ServerTlsBundle.mergeCABundles([
        List<int>.filled(
          ServerTlsBundle.maxTrustedClientCABundleBytes + 1,
          0x41,
        ),
      ]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('size limit'),
        ),
      ),
    );
  });
}

const _clientCAOne = '''-----BEGIN CERTIFICATE-----
AQID
-----END CERTIFICATE-----''';

const _clientCATwo = '''-----BEGIN CERTIFICATE-----
BAUG
-----END CERTIFICATE-----''';
