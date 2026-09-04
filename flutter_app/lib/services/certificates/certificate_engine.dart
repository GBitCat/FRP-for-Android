import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../frp_engine.dart';
import 'certificate_models.dart';

abstract interface class CertificateBackend {
  Future<CertificateInventory> listInventory();

  Future<CertificateAuthorityRecord> createAuthority({
    required String name,
    required String commonName,
    required String password,
    String organization,
    String algorithm,
    int validDays,
  });

  Future<CertificateAuthorityRecord> importAuthorityRecovery({
    required String name,
    required String password,
    required String certificatePem,
    required String encryptedKeyPayload,
  });

  Future<void> deleteAuthority(String id, {bool force});

  Future<ManagedIdentityRecord> createIdentity({
    required String name,
    required String commonName,
    String organization,
    String algorithm,
    List<String> dnsNames,
    List<String> ipAddresses,
  });

  Future<void> deleteIdentity(String id);

  Future<ManagedIdentityRecord> signIdentity({
    required String identityId,
    required String caId,
    required String password,
    int validDays,
    bool useCaAsTrustedServer,
  });

  Future<ManagedIdentityRecord> installIdentity({
    required String identityId,
    required String certificatePem,
    String trustedCaPem,
  });

  Future<ManagedIdentityRecord> installTrustedCA({
    required String identityId,
    required String trustedCaPem,
  });

  Future<CSRInspection> inspectCSR({required String csrPem});

  Future<void> validateCABundle({required String trustedCaPem});

  Future<IssuedCertificateRecord> signCSR({
    required String caId,
    required String password,
    required String csrPem,
    required String role,
    String name,
    int validDays,
  });

  Future<IssuedCertificateRecord> generateServerCertificate({
    required String caId,
    required String password,
    required String name,
    required String commonName,
    String organization,
    String algorithm,
    List<String> dnsNames,
    List<String> ipAddresses,
    int validDays,
  });

  Future<void> deleteIssuedCertificate(String id);
}

class CertificateEngine implements CertificateBackend {
  CertificateEngine._();

  static final CertificateEngine instance = CertificateEngine._();
  static const int apiVersion = 1;

  String? _storageRoot;

  Future<Map<String, dynamic>> _invoke(
    String operation, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final root = _storageRoot ??= await FrpEngine.instance.getTlsStorageRoot();
    final request = <String, dynamic>{
      'apiVersion': apiVersion,
      'operation': operation,
      'root': root,
      ...arguments,
    };
    final response = await Isolate.run(() => _invokeCertificateNative(request));
    if (response['ok'] != true) {
      throw CertificateEngineException(
        response['code'] as String? ?? 'CERTIFICATE_ENGINE_ERROR',
        response['message'] as String? ?? 'Certificate operation failed',
      );
    }
    return (response['data'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
  }

  @override
  Future<CertificateInventory> listInventory() async =>
      CertificateInventory.fromJson(await _invoke('list_inventory'));

  @override
  Future<CertificateAuthorityRecord> createAuthority({
    required String name,
    required String commonName,
    required String password,
    String organization = '',
    String algorithm = 'ecdsa-p256',
    int validDays = 3650,
  }) async => CertificateAuthorityRecord.fromJson(
    await _invoke('create_ca', {
      'name': name,
      'commonName': commonName,
      'organization': organization,
      'algorithm': algorithm,
      'password': password,
      'validDays': validDays,
    }),
  );

  @override
  Future<CertificateAuthorityRecord> importAuthorityRecovery({
    required String name,
    required String password,
    required String certificatePem,
    required String encryptedKeyPayload,
  }) async => CertificateAuthorityRecord.fromJson(
    await _invoke('import_ca_recovery', {
      'name': name,
      'password': password,
      'certificatePem': certificatePem,
      'encryptedKeyPayload': encryptedKeyPayload,
    }),
  );

  @override
  Future<void> deleteAuthority(String id, {bool force = false}) async {
    await _invoke('delete_ca', {'id': id, 'force': force});
  }

  @override
  Future<ManagedIdentityRecord> createIdentity({
    required String name,
    required String commonName,
    String organization = '',
    String algorithm = 'ecdsa-p256',
    List<String> dnsNames = const [],
    List<String> ipAddresses = const [],
  }) async => ManagedIdentityRecord.fromJson(
    await _invoke('create_identity', {
      'name': name,
      'commonName': commonName,
      'organization': organization,
      'algorithm': algorithm,
      'dnsNames': dnsNames,
      'ipAddresses': ipAddresses,
    }),
  );

  @override
  Future<void> deleteIdentity(String id) async {
    await _invoke('delete_identity', {'id': id});
  }

  @override
  Future<ManagedIdentityRecord> signIdentity({
    required String identityId,
    required String caId,
    required String password,
    int validDays = 365,
    bool useCaAsTrustedServer = false,
  }) async => ManagedIdentityRecord.fromJson(
    await _invoke('sign_identity', {
      'identityId': identityId,
      'caId': caId,
      'password': password,
      'validDays': validDays,
      'useCaAsTrustedServer': useCaAsTrustedServer,
    }),
  );

  @override
  Future<ManagedIdentityRecord> installIdentity({
    required String identityId,
    required String certificatePem,
    String trustedCaPem = '',
  }) async => ManagedIdentityRecord.fromJson(
    await _invoke('install_identity', {
      'identityId': identityId,
      'certificatePem': certificatePem,
      'trustedCaPem': trustedCaPem,
    }),
  );

  @override
  Future<ManagedIdentityRecord> installTrustedCA({
    required String identityId,
    required String trustedCaPem,
  }) async => ManagedIdentityRecord.fromJson(
    await _invoke('install_trusted_ca', {
      'identityId': identityId,
      'trustedCaPem': trustedCaPem,
    }),
  );

  @override
  Future<CSRInspection> inspectCSR({required String csrPem}) async =>
      CSRInspection.fromJson(await _invoke('inspect_csr', {'csrPem': csrPem}));

  @override
  Future<void> validateCABundle({required String trustedCaPem}) async {
    await _invoke('validate_ca_bundle', {'trustedCaPem': trustedCaPem});
  }

  @override
  Future<IssuedCertificateRecord> signCSR({
    required String caId,
    required String password,
    required String csrPem,
    required String role,
    String name = '',
    int validDays = 365,
  }) async => IssuedCertificateRecord.fromJson(
    await _invoke('sign_csr', {
      'caId': caId,
      'password': password,
      'csrPem': csrPem,
      'role': role,
      'name': name,
      'validDays': validDays,
    }),
  );

  @override
  Future<IssuedCertificateRecord> generateServerCertificate({
    required String caId,
    required String password,
    required String name,
    required String commonName,
    String organization = '',
    String algorithm = 'ecdsa-p256',
    List<String> dnsNames = const [],
    List<String> ipAddresses = const [],
    int validDays = 365,
  }) async => IssuedCertificateRecord.fromJson(
    await _invoke('generate_server_certificate', {
      'caId': caId,
      'password': password,
      'name': name,
      'commonName': commonName,
      'organization': organization,
      'algorithm': algorithm,
      'dnsNames': dnsNames,
      'ipAddresses': ipAddresses,
      'validDays': validDays,
    }),
  );

  @override
  Future<void> deleteIssuedCertificate(String id) async {
    await _invoke('delete_issued_certificate', {'id': id});
  }
}

typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();
typedef _InvokeNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _InvokeDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

Map<String, dynamic> _invokeCertificateNative(Map<String, dynamic> request) {
  try {
    final library = DynamicLibrary.open('libfrpc_cert.so');
    final version = library.lookupFunction<_VersionNative, _VersionDart>(
      'FrpCertAbiVersion',
    )();
    if (version != CertificateEngine.apiVersion) {
      return {
        'ok': false,
        'code': 'ABI_VERSION_MISMATCH',
        'message': 'Certificate engine ABI $version is not supported',
      };
    }
    final invoke = library.lookupFunction<_InvokeNative, _InvokeDart>(
      'FrpCertInvoke',
    );
    final free = library.lookupFunction<_FreeNative, _FreeDart>('FrpCertFree');
    final input = jsonEncode(request).toNativeUtf8();
    final inputAllocationLength = input.length + 1;
    Pointer<Utf8> output = nullptr;
    try {
      output = invoke(input);
      if (output == nullptr) {
        return {
          'ok': false,
          'code': 'EMPTY_NATIVE_RESPONSE',
          'message': 'Certificate engine returned no response',
        };
      }
      final decoded = jsonDecode(output.toDartString());
      if (decoded is! Map) {
        throw const FormatException('Certificate engine response is invalid');
      }
      return decoded.cast<String, dynamic>();
    } finally {
      try {
        input
            .cast<Uint8>()
            .asTypedList(inputAllocationLength)
            .fillRange(0, inputAllocationLength, 0);
      } finally {
        malloc.free(input);
        if (output != nullptr) free(output.cast<Void>());
      }
    }
  } catch (_) {
    return {
      'ok': false,
      'code': 'ENGINE_UNAVAILABLE',
      // Do not surface native loader paths, malformed response fragments, or
      // other low-level exception text through the certificate UI.
      'message': 'Certificate engine is unavailable',
    };
  }
}
