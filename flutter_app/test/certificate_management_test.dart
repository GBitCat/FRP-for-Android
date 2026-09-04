import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/screens/certificate_management_screen.dart';
import 'package:frp_app/services/certificates/certificate_engine.dart';
import 'package:frp_app/services/certificates/certificate_models.dart';

void main() {
  test('certificate inventory parses native records and derived state', () {
    final inventory = CertificateInventory.fromJson({
      'authorities': [
        {
          'id': 'ca-0123456789abcdef01234567',
          'name': 'Home CA',
          'commonName': 'home-ca',
          'algorithm': 'ecdsa-p256',
          'createdAt': '2026-09-03T00:00:00Z',
          'notAfter': '2036-09-03T00:00:00Z',
          'fingerprint': 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55',
          'certificatePath': '/private/tls/authorities/home/ca.crt',
          'encryptedKeyPath': '/private/tls/authorities/home/ca.key.enc',
          'status': 'valid',
        },
      ],
      'identities': [
        {
          'id': 'id-0123456789abcdef01234567',
          'name': 'Phone',
          'commonName': 'phone',
          'algorithm': 'ecdsa-p256',
          'dnsNames': ['phone'],
          'ipAddresses': <String>[],
          'createdAt': '2026-09-03T00:00:00Z',
          'privateKeyPath': '/private/tls/identities/phone/client.key',
          'csrPath': '/private/tls/identities/phone/client.csr',
          'certificatePath': '/private/tls/identities/phone/client.crt',
          'trustedCaPath': '/private/tls/identities/phone/ca.crt',
          'trustedCaStatus': 'valid',
          'trustedCAs': [
            {
              'subject': 'CN=frps-ca',
              'notBefore': '2026-09-03T00:00:00Z',
              'notAfter': '2036-09-03T00:00:00Z',
              'fingerprint': '99:88:77:66:55:44:33:22:11:00:AA:BB',
              'status': 'valid',
            },
          ],
          'issuer': 'home-ca',
          'notAfter': '2027-09-03T00:00:00Z',
          'fingerprint': '11:22:33:44:55:66:77:88:99:AA:BB:CC',
          'status': 'ready',
        },
      ],
      'issued': <Map<String, Object?>>[],
      'warnings': ['one damaged entry was skipped'],
    });

    expect(inventory.authorities.single.commonName, 'home-ca');
    expect(inventory.authorities.single.notAfter, isNotNull);
    expect(inventory.identities.single.isReady, isTrue);
    expect(inventory.identities.single.hasCertificate, isTrue);
    expect(inventory.identities.single.hasTrustedCA, isTrue);
    expect(inventory.identities.single.trustedCaStatus, 'valid');
    expect(inventory.identities.single.trustedCAs.single.subject, 'CN=frps-ca');
    expect(inventory.identities.single.shortFingerprint, contains('…'));
    expect(inventory.identities.single.selectionLabel, contains('Phone · '));
    expect(inventory.authorities.single.selectionLabel, contains('Home CA · '));
    expect(inventory.warnings, ['one damaged entry was skipped']);
  });

  test('CSR inspection parses immutable identity and key details', () {
    final inspection = CSRInspection.fromJson({
      'subject': 'CN=frps.example.com,O=Example',
      'commonName': 'frps.example.com',
      'organizations': ['Example'],
      'dnsNames': ['frps.example.com'],
      'ipAddresses': ['192.0.2.10'],
      'emailAddresses': <String>[],
      'uris': ['spiffe://example/frps'],
      'publicKeyAlgorithm': 'ECDSA P-256',
      'publicKeyBits': 256,
      'signatureAlgorithm': 'ECDSA-SHA256',
      'fingerprint': 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55',
      'canSignAsServer': true,
    });

    expect(inspection.commonName, 'frps.example.com');
    expect(inspection.dnsNames, ['frps.example.com']);
    expect(inspection.publicKeyAlgorithm, 'ECDSA P-256');
    expect(inspection.publicKeyBits, 256);
    expect(inspection.canSignAsServer, isTrue);
    expect(inspection.shortFingerprint, contains('…'));
  });

  test('invalid installed certificate is distinct from a pending CSR', () {
    final identity = ManagedIdentityRecord.fromJson({
      'id': 'id-0123456789abcdef01234567',
      'name': 'Damaged identity',
      'commonName': 'client',
      'algorithm': 'ecdsa-p256',
      'dnsNames': <String>[],
      'ipAddresses': <String>[],
      'privateKeyPath': '/private/client.key',
      'csrPath': '/private/client.csr',
      'certificatePath': '/private/client.crt',
      'trustedCaPath': '',
      'issuer': '',
      'fingerprint': '',
      'status': 'invalid',
    });

    expect(identity.hasCertificate, isTrue);
    expect(identity.isReady, isFalse);
  });

  testWidgets('certificate and CA management remain separate sections', (
    tester,
  ) async {
    final backend = _FakeCertificateBackend(
      CertificateInventory(authorities: [_authority]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CertificateManagementScreen(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Certificate Management'), findsOneWidget);
    expect(find.text('Device Certificates'), findsOneWidget);
    expect(find.text('Generate CSR'), findsOneWidget);
    expect(find.text('Certificate Authorities'), findsNothing);

    await tester.tap(find.text('Authorities'));
    await tester.pumpAndSettle();

    expect(find.text('Certificate Authorities'), findsOneWidget);
    expect(find.text('Create CA'), findsOneWidget);
    expect(find.text('Import Recovery'), findsOneWidget);
    expect(find.text('Home CA'), findsOneWidget);
    expect(find.text('Device Certificates'), findsNothing);
    expect(backend.listCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Generate CSR creates an identity through the backend', (
    tester,
  ) async {
    final backend = _FakeCertificateBackend(const CertificateInventory());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CertificateManagementScreen(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('certificate_generate_csr')));
    await tester.pumpAndSettle();
    expect(find.text('Generate Device CSR'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();

    expect(backend.createIdentityCalls, 1);
    expect(find.text('Android Client'), findsOneWidget);
    expect(find.text('CSR ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('certificate password fields disable keyboard assistance', (
    tester,
  ) async {
    final backend = _FakeCertificateBackend(const CertificateInventory());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CertificateManagementScreen(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Authorities'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create CA'));
    await tester.pumpAndSettle();

    final passwordFields = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .where((field) => field.obscureText)
        .toList(growable: false);
    expect(passwordFields, hasLength(2));
    expect(passwordFields.every((field) => !field.enableSuggestions), isTrue);
    expect(passwordFields.every((field) => !field.autocorrect), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed certificate action reloads authoritative inventory', (
    tester,
  ) async {
    final backend = _FakeCertificateBackend(
      const CertificateInventory(),
      failCreateIdentity: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CertificateManagementScreen(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('certificate_generate_csr')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();

    expect(backend.createIdentityCalls, 1);
    expect(backend.listCalls, 2);
    expect(find.text('simulated certificate failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate CA names stay distinct in local signing selection', (
    tester,
  ) async {
    final secondAuthority = CertificateAuthorityRecord(
      id: 'ca-fedcba9876543210fedcba98',
      name: _authority.name,
      commonName: 'home-ca-2',
      algorithm: 'ecdsa-p256',
      createdAt: null,
      notAfter: null,
      fingerprint: _authority.fingerprint,
      certificatePath: '/private/tls/authorities/home-2/ca.crt',
      encryptedKeyPath: '/private/tls/authorities/home-2/ca.key.enc',
      status: 'valid',
    );
    const identity = ManagedIdentityRecord(
      id: 'id-0123456789abcdef01234567',
      name: 'Phone',
      commonName: 'phone',
      algorithm: 'ecdsa-p256',
      dnsNames: [],
      ipAddresses: [],
      createdAt: null,
      privateKeyPath: '/private/tls/identities/phone/client.key',
      csrPath: '/private/tls/identities/phone/client.csr',
      certificatePath: '',
      trustedCaPath: '',
      issuer: '',
      notAfter: null,
      fingerprint: '',
      status: 'csr_ready',
    );
    final backend = _FakeCertificateBackend(
      CertificateInventory(
        authorities: [_authority, secondAuthority],
        identities: const [identity],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CertificateManagementScreen(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('identity_actions_${identity.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign with local CA'));
    await tester.pumpAndSettle();

    final dropdown = find.byKey(const ValueKey('certificate_signing_ca'));
    expect(dropdown, findsOneWidget);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    expect(find.text(_authority.selectionLabel), findsWidgets);
    expect(find.text(secondAuthority.selectionLabel), findsOneWidget);
    expect(_authority.selectionLabel, isNot(secondAuthority.selectionLabel));
    expect(tester.takeException(), isNull);
  });

  testWidgets('CA deletion never bypasses issued-record protection', (
    tester,
  ) async {
    final backend = _FakeCertificateBackend(
      const CertificateInventory(authorities: [_authority]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CertificateManagementScreen(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Authorities'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('authority_actions_${_authority.id}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete CA'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete CA'));
    await tester.pumpAndSettle();

    expect(backend.deletedAuthorityId, _authority.id);
    expect(backend.deletedAuthorityForce, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('archived signing CA remains selectable for frps trust', (
    tester,
  ) async {
    final backend = _FakeCertificateBackend(
      const CertificateInventory(issued: [_serverCertificate, _clientRecord]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CertificateManagementScreen(backend: backend)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('issued_actions_${_serverCertificate.id}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export encrypted frps bundle'));
    await tester.pumpAndSettle();

    expect(find.text('Trusted client CAs'), findsOneWidget);
    expect(find.text('Old client signing CA (archived)'), findsOneWidget);
    expect(
      find.text('Public CA copy retained with an issued record'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

const _authority = CertificateAuthorityRecord(
  id: 'ca-0123456789abcdef01234567',
  name: 'Home CA',
  commonName: 'home-ca',
  algorithm: 'ecdsa-p256',
  createdAt: null,
  notAfter: null,
  fingerprint: 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55',
  certificatePath: '/private/tls/authorities/home/ca.crt',
  encryptedKeyPath: '/private/tls/authorities/home/ca.key.enc',
  status: 'valid',
);

const _serverCertificate = IssuedCertificateRecord(
  id: 'cert-0123456789abcdef01234567',
  caId: 'ca-server00000000000000000000',
  name: 'FRPS Server',
  role: 'server',
  subject: 'CN=frps.example.com',
  serialNumber: '01',
  issuedAt: null,
  notAfter: null,
  fingerprint: '11:22:33:44',
  hasPrivateKey: true,
  certificatePath: '/private/issued/server/server.crt',
  privateKeyPath: '/private/issued/server/server.key',
  csrPath: '/private/issued/server/server.csr',
  caCertificatePath: '/private/issued/server/ca.crt',
  status: 'valid',
);

const _clientRecord = IssuedCertificateRecord(
  id: 'cert-fedcba9876543210fedcba98',
  caId: 'ca-client00000000000000000000',
  name: 'Old client',
  role: 'client',
  subject: 'CN=client',
  serialNumber: '02',
  issuedAt: null,
  notAfter: null,
  fingerprint: 'AA:BB:CC:DD',
  hasPrivateKey: false,
  certificatePath: '/private/issued/client/client.crt',
  privateKeyPath: '',
  csrPath: '/private/issued/client/client.csr',
  caCertificatePath: '/private/issued/client/ca.crt',
  status: 'valid',
);

class _FakeCertificateBackend implements CertificateBackend {
  _FakeCertificateBackend(this.inventory, {this.failCreateIdentity = false});

  CertificateInventory inventory;
  final bool failCreateIdentity;
  int listCalls = 0;
  int createIdentityCalls = 0;
  String? deletedAuthorityId;
  bool? deletedAuthorityForce;

  @override
  Future<CertificateInventory> listInventory() async {
    listCalls++;
    return inventory;
  }

  @override
  Future<ManagedIdentityRecord> createIdentity({
    required String name,
    required String commonName,
    String organization = '',
    String algorithm = 'ecdsa-p256',
    List<String> dnsNames = const [],
    List<String> ipAddresses = const [],
  }) async {
    createIdentityCalls++;
    if (failCreateIdentity) {
      throw const CertificateEngineException(
        'SIMULATED_FAILURE',
        'simulated certificate failure',
      );
    }
    final identity = ManagedIdentityRecord(
      id: 'id-0123456789abcdef01234567',
      name: name,
      commonName: commonName,
      algorithm: algorithm,
      dnsNames: dnsNames,
      ipAddresses: ipAddresses,
      createdAt: DateTime.utc(2026, 9, 3),
      privateKeyPath: '/private/tls/identities/phone/client.key',
      csrPath: '/private/tls/identities/phone/client.csr',
      certificatePath: '',
      trustedCaPath: '',
      trustedCaStatus: '',
      trustedCAs: const [],
      issuer: '',
      notAfter: null,
      fingerprint: '',
      status: 'csr_ready',
    );
    inventory = CertificateInventory(
      authorities: inventory.authorities,
      identities: [identity],
      issued: inventory.issued,
      warnings: inventory.warnings,
    );
    return identity;
  }

  @override
  Future<void> deleteAuthority(String id, {bool force = false}) async {
    deletedAuthorityId = id;
    deletedAuthorityForce = force;
    inventory = CertificateInventory(
      authorities: inventory.authorities
          .where((authority) => authority.id != id)
          .toList(growable: false),
      identities: inventory.identities,
      issued: inventory.issued,
      warnings: inventory.warnings,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected certificate operation');
}
