class CertificateEngineException implements Exception {
  const CertificateEngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class CertificateInventory {
  const CertificateInventory({
    this.authorities = const [],
    this.identities = const [],
    this.issued = const [],
    this.warnings = const [],
  });

  final List<CertificateAuthorityRecord> authorities;
  final List<ManagedIdentityRecord> identities;
  final List<IssuedCertificateRecord> issued;
  final List<String> warnings;

  factory CertificateInventory.fromJson(Map<String, dynamic> json) =>
      CertificateInventory(
        authorities: _objectList(json['authorities'])
            .map(CertificateAuthorityRecord.fromJson)
            .toList(growable: false),
        identities: _objectList(json['identities'])
            .map(ManagedIdentityRecord.fromJson)
            .toList(growable: false),
        issued: _objectList(json['issued'])
            .map(IssuedCertificateRecord.fromJson)
            .toList(growable: false),
        warnings: (json['warnings'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );
}

class CertificateAuthorityRecord {
  const CertificateAuthorityRecord({
    required this.id,
    required this.name,
    required this.commonName,
    required this.algorithm,
    required this.createdAt,
    required this.notAfter,
    required this.fingerprint,
    required this.certificatePath,
    required this.encryptedKeyPath,
    required this.status,
  });

  final String id;
  final String name;
  final String commonName;
  final String algorithm;
  final DateTime? createdAt;
  final DateTime? notAfter;
  final String fingerprint;
  final String certificatePath;
  final String encryptedKeyPath;
  final String status;

  String get shortFingerprint => _shortFingerprint(fingerprint);
  String get selectionLabel => _selectionLabel(name, fingerprint, id);

  factory CertificateAuthorityRecord.fromJson(Map<String, dynamic> json) =>
      CertificateAuthorityRecord(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        commonName: _string(json, 'commonName'),
        algorithm: _string(json, 'algorithm'),
        createdAt: DateTime.tryParse(_string(json, 'createdAt')),
        notAfter: DateTime.tryParse(_string(json, 'notAfter')),
        fingerprint: _string(json, 'fingerprint'),
        certificatePath: _string(json, 'certificatePath'),
        encryptedKeyPath: _string(json, 'encryptedKeyPath'),
        status: _string(json, 'status'),
      );
}

class ManagedIdentityRecord {
  const ManagedIdentityRecord({
    required this.id,
    required this.name,
    required this.commonName,
    required this.algorithm,
    required this.dnsNames,
    required this.ipAddresses,
    required this.createdAt,
    required this.privateKeyPath,
    required this.csrPath,
    required this.certificatePath,
    required this.trustedCaPath,
    this.trustedCaStatus = '',
    this.trustedCAs = const [],
    required this.issuer,
    required this.notAfter,
    required this.fingerprint,
    required this.status,
  });

  final String id;
  final String name;
  final String commonName;
  final String algorithm;
  final List<String> dnsNames;
  final List<String> ipAddresses;
  final DateTime? createdAt;
  final String privateKeyPath;
  final String csrPath;
  final String certificatePath;
  final String trustedCaPath;
  final String trustedCaStatus;
  final List<TrustedCACertificateRecord> trustedCAs;
  final String issuer;
  final DateTime? notAfter;
  final String fingerprint;
  final String status;

  bool get hasCertificate => certificatePath.isNotEmpty;
  bool get hasTrustedCA => trustedCaPath.isNotEmpty;
  bool get isReady => status == 'ready';
  String get shortFingerprint => _shortFingerprint(fingerprint);
  String get selectionLabel => _selectionLabel(name, fingerprint, id);

  factory ManagedIdentityRecord.fromJson(Map<String, dynamic> json) =>
      ManagedIdentityRecord(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        commonName: _string(json, 'commonName'),
        algorithm: _string(json, 'algorithm'),
        dnsNames: _stringList(json['dnsNames']),
        ipAddresses: _stringList(json['ipAddresses']),
        createdAt: DateTime.tryParse(_string(json, 'createdAt')),
        privateKeyPath: _string(json, 'privateKeyPath'),
        csrPath: _string(json, 'csrPath'),
        certificatePath: _string(json, 'certificatePath'),
        trustedCaPath: _string(json, 'trustedCaPath'),
        trustedCaStatus: _string(json, 'trustedCaStatus'),
        trustedCAs: _objectList(json['trustedCAs'])
            .map(TrustedCACertificateRecord.fromJson)
            .toList(growable: false),
        issuer: _string(json, 'issuer'),
        notAfter: DateTime.tryParse(_string(json, 'notAfter')),
        fingerprint: _string(json, 'fingerprint'),
        status: _string(json, 'status'),
      );
}

class TrustedCACertificateRecord {
  const TrustedCACertificateRecord({
    required this.subject,
    required this.notBefore,
    required this.notAfter,
    required this.fingerprint,
    required this.status,
  });

  final String subject;
  final DateTime? notBefore;
  final DateTime? notAfter;
  final String fingerprint;
  final String status;

  String get shortFingerprint => _shortFingerprint(fingerprint);

  factory TrustedCACertificateRecord.fromJson(Map<String, dynamic> json) =>
      TrustedCACertificateRecord(
        subject: _string(json, 'subject'),
        notBefore: DateTime.tryParse(_string(json, 'notBefore')),
        notAfter: DateTime.tryParse(_string(json, 'notAfter')),
        fingerprint: _string(json, 'fingerprint'),
        status: _string(json, 'status'),
      );
}

class IssuedCertificateRecord {
  const IssuedCertificateRecord({
    required this.id,
    required this.caId,
    required this.name,
    required this.role,
    required this.subject,
    required this.serialNumber,
    required this.issuedAt,
    required this.notAfter,
    required this.fingerprint,
    required this.hasPrivateKey,
    required this.certificatePath,
    required this.privateKeyPath,
    required this.csrPath,
    required this.caCertificatePath,
    required this.status,
  });

  final String id;
  final String caId;
  final String name;
  final String role;
  final String subject;
  final String serialNumber;
  final DateTime? issuedAt;
  final DateTime? notAfter;
  final String fingerprint;
  final bool hasPrivateKey;
  final String certificatePath;
  final String privateKeyPath;
  final String csrPath;
  final String caCertificatePath;
  final String status;

  String get shortFingerprint => _shortFingerprint(fingerprint);

  factory IssuedCertificateRecord.fromJson(Map<String, dynamic> json) =>
      IssuedCertificateRecord(
        id: _string(json, 'id'),
        caId: _string(json, 'caId'),
        name: _string(json, 'name'),
        role: _string(json, 'role'),
        subject: _string(json, 'subject'),
        serialNumber: _string(json, 'serialNumber'),
        issuedAt: DateTime.tryParse(_string(json, 'issuedAt')),
        notAfter: DateTime.tryParse(_string(json, 'notAfter')),
        fingerprint: _string(json, 'fingerprint'),
        hasPrivateKey: json['hasPrivateKey'] == true,
        certificatePath: _string(json, 'certificatePath'),
        privateKeyPath: _string(json, 'privateKeyPath'),
        csrPath: _string(json, 'csrPath'),
        caCertificatePath: _string(json, 'caCertificatePath'),
        status: _string(json, 'status'),
      );
}

class CSRInspection {
  const CSRInspection({
    required this.subject,
    required this.commonName,
    required this.organizations,
    required this.dnsNames,
    required this.ipAddresses,
    required this.emailAddresses,
    required this.uris,
    required this.publicKeyAlgorithm,
    required this.publicKeyBits,
    required this.signatureAlgorithm,
    required this.fingerprint,
    required this.canSignAsServer,
  });

  final String subject;
  final String commonName;
  final List<String> organizations;
  final List<String> dnsNames;
  final List<String> ipAddresses;
  final List<String> emailAddresses;
  final List<String> uris;
  final String publicKeyAlgorithm;
  final int publicKeyBits;
  final String signatureAlgorithm;
  final String fingerprint;
  final bool canSignAsServer;

  String get shortFingerprint => _shortFingerprint(fingerprint);

  factory CSRInspection.fromJson(Map<String, dynamic> json) => CSRInspection(
    subject: _string(json, 'subject'),
    commonName: _string(json, 'commonName'),
    organizations: _stringList(json['organizations']),
    dnsNames: _stringList(json['dnsNames']),
    ipAddresses: _stringList(json['ipAddresses']),
    emailAddresses: _stringList(json['emailAddresses']),
    uris: _stringList(json['uris']),
    publicKeyAlgorithm: _string(json, 'publicKeyAlgorithm'),
    publicKeyBits: json['publicKeyBits'] as int? ?? 0,
    signatureAlgorithm: _string(json, 'signatureAlgorithm'),
    fingerprint: _string(json, 'fingerprint'),
    canSignAsServer: json['canSignAsServer'] == true,
  );
}

List<Map<String, dynamic>> _objectList(Object? value) =>
    (value as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((entry) => entry.cast<String, dynamic>())
        .toList(growable: false);

List<String> _stringList(Object? value) => (value as List<dynamic>? ?? const [])
    .whereType<String>()
    .toList(growable: false);

String _string(Map<String, dynamic> json, String key) =>
    json[key] as String? ?? '';

String _shortFingerprint(String value) {
  if (value.length <= 23) return value;
  return '${value.substring(0, 11)}…${value.substring(value.length - 11)}';
}

String _selectionLabel(String name, String fingerprint, String id) {
  final normalizedFingerprint = fingerprint.trim();
  final normalizedId = id.trim();
  final discriminators = <String>[
    if (normalizedId.isNotEmpty) _shortIdentifier(normalizedId),
    if (normalizedFingerprint.isNotEmpty)
      _shortFingerprint(normalizedFingerprint),
  ];
  return discriminators.isEmpty
      ? name
      : '$name · ${discriminators.join(' · ')}';
}

String _shortIdentifier(String value) {
  if (value.length <= 19) return value;
  return '${value.substring(0, 10)}…${value.substring(value.length - 8)}';
}
