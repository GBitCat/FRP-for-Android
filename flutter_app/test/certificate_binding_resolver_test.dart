import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/certificates/certificate_binding_resolver.dart';
import 'package:frp_app/services/certificates/certificate_models.dart';

void main() {
  test('managed identity ID resolves current private paths', () {
    const server = ServerConfig(
      tlsEnabled: true,
      tlsIdentityId: 'id-0123456789abcdef01234567',
      tlsCertFile: '/stale/client.crt',
      tlsKeyFile: '/stale/client.key',
      tlsTrustedCaFile: '/stale/ca.crt',
    );
    final resolved = CertificateBindingResolver.requireReady(
      server,
      const CertificateInventory(identities: [_readyIdentity]),
    );

    expect(resolved.tlsCertFile, '/current/client.crt');
    expect(resolved.tlsKeyFile, '/current/client.key');
    expect(resolved.tlsTrustedCaFile, '/current/ca.crt');
    expect(resolved.hasResolvedTlsCredentials, isTrue);
  });

  test('stale or non-ready identity fails closed', () {
    const stale = ServerConfig(
      tlsEnabled: true,
      tlsIdentityId: 'id-ffffffffffffffffffffffff',
      tlsCertFile: '/attacker/client.crt',
      tlsKeyFile: '/attacker/client.key',
      tlsTrustedCaFile: '/attacker/ca.crt',
    );
    final resolved = CertificateBindingResolver.resolve(
      stale,
      const CertificateInventory(identities: [_readyIdentity]),
    );
    expect(resolved.tlsCertFile, isEmpty);
    expect(resolved.tlsKeyFile, isEmpty);
    expect(resolved.tlsTrustedCaFile, isEmpty);
    expect(resolved.tlsIdentityId, isEmpty);
    expect(
      () => CertificateBindingResolver.requireReady(
        stale,
        const CertificateInventory(identities: [_readyIdentity]),
      ),
      throwsA(isA<CertificateBindingException>()),
    );
  });

  test(
    'known but incomplete identity keeps selection while clearing paths',
    () {
      const pending = ManagedIdentityRecord(
        id: 'id-0123456789abcdef01234567',
        name: 'Pending identity',
        commonName: 'client',
        algorithm: 'ecdsa-p256',
        dnsNames: [],
        ipAddresses: [],
        createdAt: null,
        privateKeyPath: '/current/client.key',
        csrPath: '/current/client.csr',
        certificatePath: '',
        trustedCaPath: '',
        issuer: '',
        notAfter: null,
        fingerprint: '',
        status: 'csr_ready',
      );
      const server = ServerConfig(
        tlsEnabled: true,
        tlsIdentityId: 'id-0123456789abcdef01234567',
        tlsCertFile: '/stale/client.crt',
        tlsKeyFile: '/stale/client.key',
        tlsTrustedCaFile: '/stale/ca.crt',
      );

      final resolved = CertificateBindingResolver.resolve(
        server,
        const CertificateInventory(identities: [pending]),
      );

      expect(resolved.tlsIdentityId, pending.id);
      expect(resolved.hasLegacyTlsPaths, isFalse);
    },
  );

  test(
    'legacy paths migrate only when they match a ready managed identity',
    () {
      const legacy = ServerConfig(
        tlsEnabled: true,
        tlsCertFile: '/current/client.crt',
        tlsKeyFile: '/current/client.key',
        tlsTrustedCaFile: '/current/ca.crt',
      );
      final resolved = CertificateBindingResolver.resolve(
        legacy,
        const CertificateInventory(identities: [_readyIdentity]),
        allowLegacyPathMigration: true,
      );
      expect(resolved.tlsIdentityId, _readyIdentity.id);

      final rejected = CertificateBindingResolver.resolve(
        legacy.copyWith(tlsKeyFile: '/different/client.key'),
        const CertificateInventory(identities: [_readyIdentity]),
        allowLegacyPathMigration: true,
      );
      expect(rejected.tlsIdentityId, isEmpty);
      expect(rejected.hasLegacyTlsPaths, isFalse);
    },
  );

  test('deleting an identity removes its binding and runtime paths', () {
    const server = ServerConfig(
      serverAddr: 'frps.example.com',
      tlsEnabled: true,
      tlsIdentityId: 'id-0123456789abcdef01234567',
      tlsCertFile: '/current/client.crt',
      tlsKeyFile: '/current/client.key',
      tlsTrustedCaFile: '/current/ca.crt',
    );
    final invalidated = CertificateBindingResolver.invalidate(
      server,
      _readyIdentity.id,
    );
    expect(invalidated.tlsIdentityId, isEmpty);
    expect(invalidated.hasLegacyTlsPaths, isFalse);
    expect(invalidated.isValid(), isFalse);
  });
}

const _readyIdentity = ManagedIdentityRecord(
  id: 'id-0123456789abcdef01234567',
  name: 'Current identity',
  commonName: 'client',
  algorithm: 'ecdsa-p256',
  dnsNames: [],
  ipAddresses: [],
  createdAt: null,
  privateKeyPath: '/current/client.key',
  csrPath: '/current/client.csr',
  certificatePath: '/current/client.crt',
  trustedCaPath: '/current/ca.crt',
  issuer: 'CN=client-ca',
  notAfter: null,
  fingerprint: 'AA:BB:CC:DD',
  status: 'ready',
);
