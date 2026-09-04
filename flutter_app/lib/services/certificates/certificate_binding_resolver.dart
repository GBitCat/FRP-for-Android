import '../../models/server_config.dart';
import 'certificate_models.dart';

class CertificateBindingException implements Exception {
  const CertificateBindingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Resolves an opaque managed-identity ID to current app-private file paths.
/// Persisted or imported paths are never accepted as authority on their own.
abstract final class CertificateBindingResolver {
  static ServerConfig resolve(
    ServerConfig server,
    CertificateInventory inventory, {
    bool allowLegacyPathMigration = false,
  }) {
    if (!server.tlsEnabled) return server.withoutRuntimeTlsPaths();

    ManagedIdentityRecord? identity;
    final identityId = server.tlsIdentityId.trim();
    if (identityId.isNotEmpty) {
      for (final candidate in inventory.identities) {
        if (candidate.id == identityId) {
          identity = candidate;
          break;
        }
      }
      // A persisted ID that no longer exists must not survive hydration. Apart
      // from being misleading in the UI, retaining it can make a later record
      // with the same corrupt/imported ID appear selected without consent.
      if (identity == null) {
        return server.copyWith(
          tlsIdentityId: '',
          tlsCertFile: '',
          tlsKeyFile: '',
          tlsTrustedCaFile: '',
        );
      }
    } else if (allowLegacyPathMigration && server.hasLegacyTlsPaths) {
      for (final candidate in inventory.identities) {
        if (candidate.certificatePath == server.tlsCertFile.trim() &&
            candidate.privateKeyPath == server.tlsKeyFile.trim() &&
            candidate.trustedCaPath == server.tlsTrustedCaFile.trim()) {
          identity = candidate;
          break;
        }
      }
    }

    if (identity == null || !identity.isReady) {
      return server.withoutRuntimeTlsPaths();
    }
    return server.copyWith(
      tlsIdentityId: identity.id,
      tlsCertFile: identity.certificatePath,
      tlsKeyFile: identity.privateKeyPath,
      tlsTrustedCaFile: identity.trustedCaPath,
    );
  }

  static ServerConfig requireReady(
    ServerConfig server,
    CertificateInventory inventory,
  ) {
    if (!server.tlsEnabled) return server.withoutRuntimeTlsPaths();
    if (server.tlsIdentityId.trim().isEmpty) {
      throw const CertificateBindingException(
        'Mutual TLS is enabled, but no certificate identity is selected.',
      );
    }
    final resolved = resolve(server, inventory);
    if (!resolved.hasResolvedTlsCredentials) {
      throw const CertificateBindingException(
        'The selected certificate identity is missing, expired, or not ready.',
      );
    }
    return resolved;
  }

  static ServerConfig invalidate(ServerConfig server, String identityId) {
    if (server.tlsIdentityId != identityId) return server;
    return server.copyWith(
      tlsIdentityId: '',
      tlsCertFile: '',
      tlsKeyFile: '',
      tlsTrustedCaFile: '',
    );
  }
}
