import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/backup_crypto.dart';
import '../services/certificates/certificate_engine.dart';
import '../services/certificates/certificate_models.dart';
import '../services/certificates/server_tls_bundle.dart';
import '../services/document_io.dart';
import '../services/limited_zip_reader.dart';
import '../services/sensitive_file_cache.dart';
import '../services/wipeable_zip_builder.dart';
import '../state/app_state.dart';
import '../widgets/app_card.dart';
import '../widgets/glass_sliver_appbar.dart';

enum _ManagementSection { certificates, authorities }

enum _IdentityAction {
  exportCSR,
  signLocally,
  importCertificate,
  importTrustedCA,
  useForServer,
  delete,
}

enum _AuthorityAction {
  exportCertificate,
  exportRecovery,
  signCSR,
  generateServer,
  delete,
}

enum _IssuedAction { exportCertificate, exportServerBundle, delete }

class CertificateManagementScreen extends StatefulWidget {
  const CertificateManagementScreen({super.key, this.backend});

  final CertificateBackend? backend;

  @override
  State<CertificateManagementScreen> createState() =>
      _CertificateManagementScreenState();
}

class _CertificateManagementScreenState
    extends State<CertificateManagementScreen> {
  static const _maxImportBytes = 2 * 1024 * 1024;

  late final CertificateBackend _backend;
  CertificateInventory _inventory = const CertificateInventory();
  _ManagementSection _section = _ManagementSection.certificates;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? CertificateEngine.instance;
    _reload();
  }

  Future<void> _reload({bool showProgress = true}) async {
    if (showProgress && mounted) setState(() => _loading = true);
    try {
      final inventory = await _backend.listInventory();
      if (!mounted) return;
      setState(() {
        _inventory = inventory;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required String successMessage,
  }) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload(showProgress: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      final message = _errorMessage(error);
      await _reload(showProgress: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            GlassSliverAppBar(
              title: 'Certificate Management',
              actions: [
                IconButton(
                  tooltip: 'Refresh certificates',
                  onPressed: _busy ? null : _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _sectionSelector(),
                  const SizedBox(height: 12),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 64),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_loadError != null)
                    _errorCard()
                  else if (_section == _ManagementSection.certificates)
                    ..._certificateSection()
                  else
                    ..._authoritySection(),
                ]),
              ),
            ),
          ],
        ),
        if (_busy)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _sectionSelector() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<_ManagementSection>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: _ManagementSection.certificates,
            icon: Icon(Icons.badge_outlined, size: 18),
            label: Text('Certificates'),
          ),
          ButtonSegment(
            value: _ManagementSection.authorities,
            icon: Icon(Icons.account_balance_outlined, size: 18),
            label: Text('Authorities'),
          ),
        ],
        selected: {_section},
        onSelectionChanged: _busy
            ? null
            : (selection) => setState(() => _section = selection.single),
      ),
    );
  }

  Widget _errorCard() => AppCard(
    leading: const Icon(Icons.error_outline),
    title: 'Certificate engine unavailable',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_loadError ?? 'Unable to load certificate storage.'),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      ],
    ),
  );

  List<Widget> _certificateSection() {
    final widgets = <Widget>[
      AppCard(
        leading: const Icon(Icons.phonelink_lock_outlined),
        title: 'Device Certificates',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Generate the private key on this device, export only its CSR, '
              'then install the signed client certificate and trusted server CA.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('certificate_generate_csr'),
              onPressed: _busy ? null : _createIdentity,
              icon: const Icon(Icons.add_card_outlined),
              label: const Text('Generate CSR'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ];

    if (_inventory.identities.isEmpty) {
      widgets.add(
        _emptyCard(
          icon: Icons.badge_outlined,
          title: 'No device identities',
          message: 'Generate a CSR to create the first local device identity.',
        ),
      );
    } else {
      widgets.addAll(
        _inventory.identities.expand(
          (identity) => [_identityCard(identity), const SizedBox(height: 10)],
        ),
      );
    }

    widgets.addAll([
      const SizedBox(height: 4),
      Text(
        'Issued Certificates',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
    ]);
    if (_inventory.issued.isEmpty) {
      widgets.add(
        _emptyCard(
          icon: Icons.workspace_premium_outlined,
          title: 'No issued certificates',
          message: 'Certificates signed by a managed CA will appear here.',
        ),
      );
    } else {
      widgets.addAll(
        _inventory.issued.expand(
          (certificate) => [
            _issuedCard(certificate),
            const SizedBox(height: 10),
          ],
        ),
      );
    }
    return widgets;
  }

  List<Widget> _authoritySection() {
    final widgets = <Widget>[
      AppCard(
        leading: const Icon(Icons.account_balance_outlined),
        title: 'Certificate Authorities',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CA private keys are password-encrypted. Use a managed CA to sign '
              'this device, an external CSR, or a locally generated frps certificate.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('certificate_create_ca'),
                  onPressed: _busy ? null : _createAuthority,
                  icon: const Icon(Icons.add_moderator_outlined),
                  label: const Text('Create CA'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importAuthorityRecovery,
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Import Recovery'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ];
    if (_inventory.authorities.isEmpty) {
      widgets.add(
        _emptyCard(
          icon: Icons.account_balance_outlined,
          title: 'No certificate authorities',
          message: 'Create a CA or import an encrypted CA recovery package.',
        ),
      );
    } else {
      widgets.addAll(
        _inventory.authorities.expand(
          (authority) => [
            _authorityCard(authority),
            const SizedBox(height: 10),
          ],
        ),
      );
    }
    if (_inventory.warnings.isNotEmpty) {
      widgets.addAll([
        const SizedBox(height: 4),
        AppCard(
          leading: const Icon(Icons.warning_amber_outlined),
          title: 'Storage warnings',
          child: Text(_inventory.warnings.join('\n')),
        ),
      ]);
    }
    return widgets;
  }

  Widget _identityCard(ManagedIdentityRecord identity) {
    final color = _statusColor(identity.status);
    return AppCard(
      leading: Icon(Icons.badge_outlined, color: color),
      title: identity.name,
      trailing: PopupMenuButton<_IdentityAction>(
        key: ValueKey('identity_actions_${identity.id}'),
        enabled: !_busy,
        onSelected: (action) => _handleIdentityAction(identity, action),
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: _IdentityAction.exportCSR,
            child: Text('Export CSR'),
          ),
          if (_inventory.authorities.isNotEmpty)
            const PopupMenuItem(
              value: _IdentityAction.signLocally,
              child: Text('Sign with local CA'),
            ),
          const PopupMenuItem(
            value: _IdentityAction.importCertificate,
            child: Text('Import signed certificate'),
          ),
          const PopupMenuItem(
            value: _IdentityAction.importTrustedCA,
            child: Text('Import trusted server CA'),
          ),
          if (identity.isReady)
            const PopupMenuItem(
              value: _IdentityAction.useForServer,
              child: Text('Use for Server Config'),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _IdentityAction.delete,
            child: Text('Delete identity'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statusLine(identity.status),
          const SizedBox(height: 6),
          _detailLine('Subject', identity.commonName),
          _detailLine('Algorithm', _algorithmLabel(identity.algorithm)),
          if (identity.notAfter != null)
            _detailLine('Expires', _formatDate(identity.notAfter)),
          if (identity.fingerprint.isNotEmpty)
            _detailLine(
              'Fingerprint',
              identity.shortFingerprint,
              monospace: true,
            ),
          if (identity.hasTrustedCA)
            _detailLine(
              'Trusted CA',
              '${identity.trustedCAs.length} certificate(s) · '
                  '${_statusLabel(identity.trustedCaStatus)}',
            ),
          if (!identity.hasCertificate)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Waiting for a signed client certificate.'),
            )
          else if (identity.status == 'invalid' ||
              identity.status == 'expired' ||
              identity.status == 'not_yet_valid')
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Replace the signed client certificate; it is invalid, weak, '
                'expired, or does not match this identity.',
              ),
            )
          else if (!identity.hasTrustedCA)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Import the CA that signed the frps server certificate.',
              ),
            )
          else if (!identity.isReady)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Replace the trusted server CA bundle before using this identity.',
              ),
            ),
        ],
      ),
    );
  }

  Widget _authorityCard(CertificateAuthorityRecord authority) {
    final color = _statusColor(authority.status);
    return AppCard(
      leading: Icon(Icons.account_balance_outlined, color: color),
      title: authority.name,
      trailing: PopupMenuButton<_AuthorityAction>(
        key: ValueKey('authority_actions_${authority.id}'),
        enabled: !_busy,
        onSelected: (action) => _handleAuthorityAction(authority, action),
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: _AuthorityAction.exportCertificate,
            child: Text('Export CA certificate'),
          ),
          PopupMenuItem(
            value: _AuthorityAction.exportRecovery,
            child: Text('Export encrypted recovery'),
          ),
          PopupMenuItem(
            value: _AuthorityAction.signCSR,
            child: Text('Sign external CSR'),
          ),
          PopupMenuItem(
            value: _AuthorityAction.generateServer,
            child: Text('Generate frps certificate'),
          ),
          PopupMenuDivider(),
          PopupMenuItem(
            value: _AuthorityAction.delete,
            child: Text('Delete CA'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statusLine(authority.status),
          const SizedBox(height: 6),
          _detailLine('Common Name', authority.commonName),
          _detailLine('Algorithm', _algorithmLabel(authority.algorithm)),
          _detailLine('Expires', _formatDate(authority.notAfter)),
          _detailLine(
            'Fingerprint',
            authority.shortFingerprint,
            monospace: true,
          ),
          const SizedBox(height: 6),
          Text(
            'Private key: password-encrypted',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _issuedCard(IssuedCertificateRecord certificate) {
    return AppCard(
      leading: Icon(
        certificate.role == 'server'
            ? Icons.dns_outlined
            : Icons.devices_outlined,
        color: _statusColor(certificate.status),
      ),
      title: certificate.name,
      trailing: PopupMenuButton<_IssuedAction>(
        key: ValueKey('issued_actions_${certificate.id}'),
        enabled: !_busy,
        onSelected: (action) => _handleIssuedAction(certificate, action),
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: _IssuedAction.exportCertificate,
            child: Text('Export certificate'),
          ),
          if (certificate.hasPrivateKey)
            const PopupMenuItem(
              value: _IssuedAction.exportServerBundle,
              child: Text('Export encrypted frps bundle'),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _IssuedAction.delete,
            child: Text('Delete record'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statusLine(certificate.status),
          const SizedBox(height: 6),
          _detailLine('Role', certificate.role.toUpperCase()),
          _detailLine('Subject', certificate.subject),
          _detailLine('Expires', _formatDate(certificate.notAfter)),
          _detailLine(
            'Fingerprint',
            certificate.shortFingerprint,
            monospace: true,
          ),
          if (certificate.hasPrivateKey)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Includes a locally generated private key.'),
            ),
        ],
      ),
    );
  }

  Widget _emptyCard({
    required IconData icon,
    required String title,
    required String message,
  }) => AppCard(
    leading: Icon(icon),
    title: title,
    child: Text(message, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget _statusLine(String status) {
    final color = _statusColor(status);
    return Row(
      children: [
        StatusDot(color),
        const SizedBox(width: 6),
        Text(
          _statusLabel(status),
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: color),
        ),
      ],
    );
  }

  Widget _detailLine(String label, String value, {bool monospace = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontFamily: monospace ? 'monospace' : null),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createAuthority() async {
    final draft = await _showCreateAuthorityDialog();
    if (draft == null || !mounted) return;
    await _runAction(() async {
      await _backend.createAuthority(
        name: draft.name,
        commonName: draft.commonName,
        organization: draft.organization,
        algorithm: draft.algorithm,
        validDays: draft.validDays,
        password: draft.password,
      );
    }, successMessage: 'Certificate authority created');
  }

  Future<void> _createIdentity() async {
    final draft = await _showCreateIdentityDialog();
    if (draft == null || !mounted) return;
    await _runAction(() async {
      await _backend.createIdentity(
        name: draft.name,
        commonName: draft.commonName,
        organization: draft.organization,
        algorithm: draft.algorithm,
        dnsNames: _splitValues(draft.dnsNames),
        ipAddresses: _splitValues(draft.ipAddresses),
      );
    }, successMessage: 'Private key and CSR generated on this device');
  }

  Future<void> _handleIdentityAction(
    ManagedIdentityRecord identity,
    _IdentityAction action,
  ) async {
    switch (action) {
      case _IdentityAction.exportCSR:
        await _exportPublicFile(
          identity.csrPath,
          _safeFileName(identity.name, suffix: '.csr'),
          'application/pkcs10',
        );
        return;
      case _IdentityAction.signLocally:
        await _signIdentityLocally(identity);
        return;
      case _IdentityAction.importCertificate:
        await _importIdentityCertificate(identity);
        return;
      case _IdentityAction.importTrustedCA:
        await _importTrustedCA(identity);
        return;
      case _IdentityAction.useForServer:
        await _useIdentityForServer(identity);
        return;
      case _IdentityAction.delete:
        await _deleteIdentity(identity);
        return;
    }
  }

  Future<void> _handleAuthorityAction(
    CertificateAuthorityRecord authority,
    _AuthorityAction action,
  ) async {
    switch (action) {
      case _AuthorityAction.exportCertificate:
        await _exportPublicFile(
          authority.certificatePath,
          _safeFileName(authority.name, suffix: '-ca.crt'),
          'application/x-x509-ca-cert',
        );
        return;
      case _AuthorityAction.exportRecovery:
        await _exportAuthorityRecovery(authority);
        return;
      case _AuthorityAction.signCSR:
        await _signExternalCSR(authority);
        return;
      case _AuthorityAction.generateServer:
        await _generateServerCertificate(authority);
        return;
      case _AuthorityAction.delete:
        await _deleteAuthority(authority);
        return;
    }
  }

  Future<void> _handleIssuedAction(
    IssuedCertificateRecord certificate,
    _IssuedAction action,
  ) async {
    switch (action) {
      case _IssuedAction.exportCertificate:
        await _exportPublicFile(
          certificate.certificatePath,
          _safeFileName(certificate.name, suffix: '.crt'),
          'application/x-x509-user-cert',
        );
        return;
      case _IssuedAction.exportServerBundle:
        await _exportServerBundle(certificate);
        return;
      case _IssuedAction.delete:
        await _deleteIssued(certificate);
        return;
    }
  }

  Future<void> _signIdentityLocally(ManagedIdentityRecord identity) async {
    final draft = await _showSignIdentityDialog(identity);
    if (draft == null || !mounted) return;
    await _runAction(
      () async {
        await _backend.signIdentity(
          identityId: identity.id,
          caId: draft.caId,
          password: draft.password,
          validDays: draft.validDays,
          useCaAsTrustedServer: draft.useCaAsTrustedServer,
        );
        if (identical(_backend, CertificateEngine.instance)) {
          await appState.refreshCertificateIdentity(identity.id);
        }
      },
      successMessage: draft.useCaAsTrustedServer
          ? 'Client certificate signed and trusted CA installed'
          : 'Client certificate signed',
    );
  }

  Future<void> _importIdentityCertificate(
    ManagedIdentityRecord identity,
  ) async {
    final certificate = await _pickTextFile([
      'application/x-x509-user-cert',
      'application/x-pem-file',
      'text/plain',
    ]);
    if (certificate == null) return;
    if (!mounted) return;
    final includeCA = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Trusted server CA'),
        content: const Text(
          'Do you also want to select the CA certificate used to verify frps?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Certificate only'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Select CA'),
          ),
        ],
      ),
    );
    if (includeCA == null || !mounted) return;
    String trustedCA = '';
    if (includeCA) {
      final selected = await _pickTextFile([
        'application/x-x509-ca-cert',
        'application/x-pem-file',
        'text/plain',
      ]);
      if (selected == null || !mounted) return;
      trustedCA = selected;
    }
    await _runAction(() async {
      await _backend.installIdentity(
        identityId: identity.id,
        certificatePem: certificate,
        trustedCaPem: trustedCA,
      );
      if (identical(_backend, CertificateEngine.instance)) {
        await appState.refreshCertificateIdentity(identity.id);
      }
    }, successMessage: 'Signed client certificate installed');
  }

  Future<void> _importTrustedCA(ManagedIdentityRecord identity) async {
    final trustedCA = await _pickTextFile([
      'application/x-x509-ca-cert',
      'application/x-pem-file',
      'text/plain',
    ]);
    if (trustedCA == null || !mounted) return;
    await _runAction(() async {
      await _backend.installTrustedCA(
        identityId: identity.id,
        trustedCaPem: trustedCA,
      );
      if (identical(_backend, CertificateEngine.instance)) {
        await appState.refreshCertificateIdentity(identity.id);
      }
    }, successMessage: 'Trusted server CA installed');
  }

  Future<void> _signExternalCSR(CertificateAuthorityRecord authority) async {
    final csr = await _pickTextFile([
      'application/pkcs10',
      'application/x-pem-file',
      'text/plain',
    ]);
    if (csr == null || !mounted) return;
    CSRInspection inspection;
    setState(() => _busy = true);
    try {
      inspection = await _backend.inspectCSR(csrPem: csr);
    } catch (error) {
      if (mounted) _showMessage(_errorMessage(error), error: true);
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final draft = await _showSignCSRDialog(authority, inspection);
    if (draft == null || !mounted) return;
    await _runAction(() async {
      await _backend.signCSR(
        caId: authority.id,
        password: draft.password,
        csrPem: csr,
        role: draft.role,
        name: draft.name,
        validDays: draft.validDays,
      );
    }, successMessage: '${draft.role.toUpperCase()} certificate signed');
  }

  Future<void> _generateServerCertificate(
    CertificateAuthorityRecord authority,
  ) async {
    final draft = await _showGenerateServerDialog(authority);
    if (draft == null || !mounted) return;
    await _runAction(() async {
      await _backend.generateServerCertificate(
        caId: authority.id,
        password: draft.password,
        name: draft.name,
        commonName: draft.commonName,
        organization: draft.organization,
        algorithm: draft.algorithm,
        dnsNames: _splitValues(draft.dnsNames),
        ipAddresses: _splitValues(draft.ipAddresses),
        validDays: draft.validDays,
      );
    }, successMessage: 'frps certificate and private key generated');
  }

  Future<void> _useIdentityForServer(ManagedIdentityRecord identity) async {
    if (appState.servers.isEmpty) {
      _showMessage('Create a Server Config before assigning a certificate.');
      return;
    }
    final binding = await _showServerBindingDialog(identity);
    if (binding == null || !mounted) return;
    final server = appState.servers.firstWhere(
      (entry) => entry.serverId == binding.serverId,
    );
    await _runAction(
      () => appState.saveServerConfig(
        server.copyWith(
          tlsEnabled: true,
          tlsServerName: binding.serverName,
          tlsIdentityId: identity.id,
          tlsCertFile: identity.certificatePath,
          tlsKeyFile: identity.privateKeyPath,
          tlsTrustedCaFile: identity.trustedCaPath,
        ),
        originalServerId: server.serverId,
      ),
      successMessage: 'Certificate assigned to ${server.name}',
    );
  }

  Future<void> _deleteIdentity(ManagedIdentityRecord identity) async {
    final confirmed = await _confirm(
      title: 'Delete device identity?',
      message:
          'This permanently removes ${identity.name}, including its private key. '
          'Server Config paths using it will stop working.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    await _runAction(() async {
      // Remove every persisted runtime binding first. If native deletion then
      // fails, an unused identity remains recoverable; the inverse ordering can
      // leave an active Server Config pointing at a deleted private key.
      await appState.invalidateCertificateIdentity(identity.id);
      try {
        await _backend.deleteIdentity(identity.id);
      } catch (error, stackTrace) {
        // A native error can occur either before or after the filesystem commit
        // point. AppState clears its tombstone only if a fresh inventory proves
        // that the ready identity still exists and can safely be rebound.
        try {
          await appState.rollbackCertificateIdentityInvalidation(identity.id);
        } catch (_) {}
        Error.throwWithStackTrace(error, stackTrace);
      }
      // A stale Server Config form can save the former ID while native deletion
      // is in flight. Clear that race after deletion commits; later stale saves
      // are rejected by AppState's inventory validation.
      await appState.invalidateCertificateIdentity(identity.id);
    }, successMessage: 'Device identity deleted');
  }

  Future<void> _deleteAuthority(CertificateAuthorityRecord authority) async {
    final confirmed = await _confirm(
      title: 'Delete certificate authority?',
      message:
          'This permanently removes the encrypted CA private key for '
          '${authority.name}. Delete its issued certificate records first. '
          'Existing exported certificates are not affected, but new certificates '
          'cannot be issued unless you have a recovery package.',
      confirmLabel: 'Delete CA',
    );
    if (!confirmed) return;
    await _runAction(
      // Keep CA material available while any issued record depends on it. This
      // prevents an accidental force-delete from making future frps trust
      // bundles impossible to reconstruct.
      () => _backend.deleteAuthority(authority.id, force: false),
      successMessage: 'Certificate authority deleted',
    );
  }

  Future<void> _deleteIssued(IssuedCertificateRecord certificate) async {
    final confirmed = await _confirm(
      title: 'Delete issued certificate record?',
      message: certificate.hasPrivateKey
          ? 'This also permanently removes the locally generated server private key.'
          : 'The exported certificate on another device is not affected.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    await _runAction(
      () => _backend.deleteIssuedCertificate(certificate.id),
      successMessage: 'Issued certificate record deleted',
    );
  }

  Future<void> _exportPublicFile(
    String sourcePath,
    String fileName,
    String mimeType,
  ) async {
    File? temporary;
    Directory? exportCacheDirectory;
    try {
      exportCacheDirectory = await getTemporaryDirectory();
      temporary = await SensitiveFileCache.createManagedExportFile(
        exportCacheDirectory,
        fileName,
      );
      await SensitiveFileCache.copyBoundedFile(
        File(sourcePath),
        temporary,
        maxBytes: _maxImportBytes,
      );
      final saved = await DocumentIo.saveFile(
        sourceFilePath: temporary.path,
        fileName: fileName,
        mimeTypes: [mimeType, 'application/x-pem-file', 'text/plain'],
      );
      if (!mounted || saved == null) return;
      _showMessage('Exported $fileName');
    } catch (error) {
      if (mounted) _showMessage(_errorMessage(error), error: true);
    } finally {
      if (temporary != null && exportCacheDirectory != null) {
        await SensitiveFileCache.deleteManagedExportFile(
          temporary,
          exportCacheDirectory,
        );
      }
    }
  }

  Future<void> _exportAuthorityRecovery(
    CertificateAuthorityRecord authority,
  ) async {
    final backupPassword = await _requestPassword(
      title: 'Protect CA recovery',
      description:
          'Use a new password of at least 12 characters. The CA key remains '
          'protected by its original CA password inside this encrypted backup.',
      confirm: true,
    );
    if (backupPassword == null || !mounted) return;
    File? temporary;
    Directory? exportCacheDirectory;
    final inMemoryFiles = <List<int>>[];
    try {
      final certificate = await SensitiveFileCache.readBoundedFile(
        File(authority.certificatePath),
        maxBytes: _maxImportBytes,
      );
      final encryptedKey = await SensitiveFileCache.readBoundedFile(
        File(authority.encryptedKeyPath),
        maxBytes: _maxImportBytes,
      );
      inMemoryFiles
        ..add(certificate)
        ..add(encryptedKey);
      final manifest = utf8.encode(
        jsonEncode({
          'version': 1,
          'name': authority.name,
          'commonName': authority.commonName,
          'fingerprint': authority.fingerprint,
        }),
      );
      inMemoryFiles.add(manifest);
      final zip = WipeableStoredZipBuilder.build([
        WipeableZipEntry('ca.crt', certificate),
        WipeableZipEntry('ca.key.enc', encryptedKey),
        WipeableZipEntry('metadata.json', manifest),
      ], maxOutputBytes: BackupCrypto.maxEncryptedBytes);
      inMemoryFiles.add(zip);
      final encrypted = await BackupCrypto.encrypt(zip, backupPassword);
      inMemoryFiles.add(encrypted);
      exportCacheDirectory = await getTemporaryDirectory();
      final fileName = _safeFileName(authority.name, suffix: '.frpca');
      temporary = await SensitiveFileCache.createManagedExportFile(
        exportCacheDirectory,
        fileName,
      );
      await temporary.writeAsBytes(encrypted, flush: true);
      final saved = await DocumentIo.saveFile(
        sourceFilePath: temporary.path,
        fileName: fileName,
        mimeTypes: const ['application/octet-stream'],
      );
      if (mounted && saved != null) {
        _showMessage('Encrypted CA recovery exported');
      }
    } catch (error) {
      if (mounted) _showMessage(_errorMessage(error), error: true);
    } finally {
      for (final bytes in inMemoryFiles) {
        bytes.fillRange(0, bytes.length, 0);
      }
      if (temporary != null && exportCacheDirectory != null) {
        await SensitiveFileCache.deleteManagedExportFile(
          temporary,
          exportCacheDirectory,
        );
      }
    }
  }

  Future<void> _importAuthorityRecovery() async {
    Uint8List? bytes;
    try {
      try {
        bytes = await _pickBinaryFile(const ['application/octet-stream']);
      } catch (error) {
        if (mounted) _showMessage(_errorMessage(error), error: true);
        return;
      }
      if (bytes == null || !mounted) return;
      if (!BackupCrypto.isEncrypted(bytes)) {
        _showMessage(
          'This is not an encrypted FRP CA recovery file.',
          error: true,
        );
        return;
      }
      final backupPassword = await _requestPassword(
        title: 'Decrypt CA recovery',
        description: 'Enter the recovery package password.',
      );
      if (backupPassword == null || !mounted) return;
      final caPassword = await _requestPassword(
        title: 'Unlock CA private key',
        description:
            'Enter the original password used when this CA was created.',
      );
      if (caPassword == null || !mounted) return;
      final recoveryBytes = bytes;
      await _runAction(() async {
        final decrypted = await BackupCrypto.decrypt(
          recoveryBytes,
          backupPassword,
        );
        Map<String, Uint8List>? files;
        try {
          files = LimitedZipReader.readRequiredFiles(
            decrypted,
            requiredFileNames: const {'ca.crt', 'ca.key.enc', 'metadata.json'},
            maxEntries: 3,
            maxEntryBytes: _maxImportBytes,
            maxTotalBytes: BackupCrypto.maxEncryptedBytes,
            allowAdditionalFiles: false,
            allowDirectories: false,
          );
          final certificate = utf8.decode(files['ca.crt']!);
          final encryptedKey = utf8.decode(files['ca.key.enc']!);
          final metadata = jsonDecode(utf8.decode(files['metadata.json']!));
          if (metadata is! Map || metadata['version'] != 1) {
            throw const FormatException('CA recovery metadata is invalid');
          }
          await _backend.importAuthorityRecovery(
            name: metadata['name'] as String? ?? 'Imported CA',
            password: caPassword,
            certificatePem: certificate,
            encryptedKeyPayload: encryptedKey,
          );
        } finally {
          decrypted.fillRange(0, decrypted.length, 0);
          for (final contents in files?.values ?? const <Uint8List>[]) {
            contents.fillRange(0, contents.length, 0);
          }
        }
      }, successMessage: 'Certificate authority recovered');
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _exportServerBundle(IssuedCertificateRecord certificate) async {
    final trustSelection = await _showTrustedClientCAsDialog(certificate);
    if (trustSelection == null || !mounted) return;
    Uint8List? externalCABundle;
    File? temporary;
    Directory? exportCacheDirectory;
    final inMemoryFiles = <Uint8List>[];
    try {
      if (trustSelection.certificatePaths.length >
          ServerTlsBundle.maxTrustedClientCACertificates) {
        throw const FormatException(
          'Select no more than 64 trusted client CAs',
        );
      }
      if (trustSelection.includeExternalBundle) {
        externalCABundle = await _pickBinaryFile([
          'application/x-x509-ca-cert',
          'application/x-pem-file',
          'text/plain',
        ]);
        if (externalCABundle == null) return;
        inMemoryFiles.add(externalCABundle);
        if (!mounted) return;
      }
      final password = await _requestPassword(
        title: 'Protect frps bundle',
        description: 'The bundle contains a server private key. Use at least 12 characters.',
        confirm: true,
      );
      if (password == null || !mounted) return;
      final certificateBytes = await SensitiveFileCache.readBoundedFile(
        File(certificate.certificatePath),
        maxBytes: _maxImportBytes,
      );
      inMemoryFiles.add(certificateBytes);
      final keyBytes = await SensitiveFileCache.readBoundedFile(
        File(certificate.privateKeyPath),
        maxBytes: _maxImportBytes,
      );
      inMemoryFiles.add(keyBytes);
      final serverSigningCA = await SensitiveFileCache.readBoundedFile(
        File(certificate.caCertificatePath),
        maxBytes: _maxImportBytes,
      );
      inMemoryFiles.add(serverSigningCA);
      final trustedClientCAs = <Uint8List>[];
      var remainingTrustedCABytes =
          ServerTlsBundle.maxTrustedClientCABundleBytes -
          (externalCABundle?.length ?? 0);
      for (final path in trustSelection.certificatePaths) {
        if (remainingTrustedCABytes <= 0) {
          throw const FormatException(
            'Trusted client CA bundle exceeds the size limit',
          );
        }
        final trustedCA = await SensitiveFileCache.readBoundedFile(
          File(path),
          maxBytes: remainingTrustedCABytes,
        );
        remainingTrustedCABytes -= trustedCA.length;
        trustedClientCAs.add(trustedCA);
        inMemoryFiles.add(trustedCA);
      }
      if (externalCABundle != null) trustedClientCAs.add(externalCABundle);
      final mergedTrustedClientCAs = ServerTlsBundle.mergeCABundles(
        trustedClientCAs,
      );
      inMemoryFiles.add(mergedTrustedClientCAs);
      await _backend.validateCABundle(
        trustedCaPem: utf8.decode(mergedTrustedClientCAs),
      );
      final plaintextZip = ServerTlsBundle.build(
        serverCertificate: certificateBytes,
        serverPrivateKey: keyBytes,
        serverSigningCA: serverSigningCA,
        trustedClientCAs: [mergedTrustedClientCAs],
      );
      inMemoryFiles.add(plaintextZip);
      final encryptedBundle = await BackupCrypto.encrypt(
        plaintextZip,
        password,
      );
      inMemoryFiles.add(encryptedBundle);
      exportCacheDirectory = await getTemporaryDirectory();
      final fileName = _safeFileName(certificate.name, suffix: '-frps.frptls');
      temporary = await SensitiveFileCache.createManagedExportFile(
        exportCacheDirectory,
        fileName,
      );
      await temporary.writeAsBytes(encryptedBundle, flush: true);
      final saved = await DocumentIo.saveFile(
        sourceFilePath: temporary.path,
        fileName: fileName,
        mimeTypes: const ['application/octet-stream'],
      );
      if (mounted && saved != null) {
        _showMessage('Encrypted frps bundle exported');
      }
    } catch (error) {
      if (mounted) _showMessage(_errorMessage(error), error: true);
    } finally {
      for (final bytes in inMemoryFiles) {
        bytes.fillRange(0, bytes.length, 0);
      }
      if (temporary != null && exportCacheDirectory != null) {
        await SensitiveFileCache.deleteManagedExportFile(
          temporary,
          exportCacheDirectory,
        );
      }
    }
  }

  Future<_TrustedClientCASelection?> _showTrustedClientCAsDialog(
    IssuedCertificateRecord certificate,
  ) async {
    CertificateAuthorityRecord? signingAuthority;
    for (final authority in _inventory.authorities) {
      if (authority.id == certificate.caId) {
        signingAuthority = authority;
        break;
      }
    }
    final currentAuthorityIds = _inventory.authorities
        .map((authority) => authority.id)
        .toSet();
    final archivedAuthorityIds = <String>{};
    final choices = <_TrustedClientCAChoice>[
      _TrustedClientCAChoice(
        id: 'server-signing-ca',
        title: signingAuthority == null
            ? 'Server signing CA'
            : '${signingAuthority.name} (server signing CA)',
        subtitle: signingAuthority == null
            ? 'Select explicitly only when this CA also signs clients.'
            : 'Same-CA deployment · ${signingAuthority.shortFingerprint}',
        certificatePath: certificate.caCertificatePath,
      ),
      for (final authority in _inventory.authorities)
        if (authority.id != certificate.caId)
          _TrustedClientCAChoice(
            id: authority.id,
            title: authority.name,
            subtitle: 'Client-signing CA · ${authority.shortFingerprint}',
            certificatePath: authority.certificatePath,
          ),
      // Older versions allowed force-deleting a CA while issued records still
      // retained an immutable public copy. Surface one copy per missing CA so
      // those client certificates can still be trusted by a new frps bundle.
      for (final issued in _inventory.issued)
        if (issued.caId != certificate.caId &&
            issued.caId.isNotEmpty &&
            issued.caCertificatePath.isNotEmpty &&
            !currentAuthorityIds.contains(issued.caId) &&
            archivedAuthorityIds.add(issued.caId))
          _TrustedClientCAChoice(
            id: 'archived-${issued.caId}',
            title: '${issued.name} signing CA (archived)',
            subtitle: 'Public CA copy retained with an issued record',
            certificatePath: issued.caCertificatePath,
          ),
    ];
    final selected = <String>{};
    var includeExternalBundle = false;
    var showSelectionError = false;
    if (!mounted) return null;
    return showDialog<_TrustedClientCASelection>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Trusted client CAs'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select every CA whose client certificates frps should '
                    'accept. The CA that signed server.crt is not selected '
                    'automatically.',
                  ),
                  const SizedBox(height: 10),
                  for (final choice in choices)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: selected.contains(choice.id),
                      title: Text(choice.title),
                      subtitle: Text(choice.subtitle),
                      onChanged: (value) => setDialogState(() {
                        if (value == true) {
                          selected.add(choice.id);
                        } else {
                          selected.remove(choice.id);
                        }
                        showSelectionError = false;
                      }),
                    ),
                  CheckboxListTile(
                    key: const ValueKey('include_external_client_ca_bundle'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: includeExternalBundle,
                    title: const Text('Add CA bundle from a file'),
                    subtitle: const Text(
                      'Use this for client CAs managed on other devices.',
                    ),
                    onChanged: (value) => setDialogState(() {
                      includeExternalBundle = value == true;
                      showSelectionError = false;
                    }),
                  ),
                  if (showSelectionError)
                    Text(
                      'Select at least one client CA.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('confirm_trusted_client_cas'),
              onPressed: () {
                if (selected.isEmpty && !includeExternalBundle) {
                  setDialogState(() => showSelectionError = true);
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  _TrustedClientCASelection(
                    certificatePaths: choices
                        .where((choice) => selected.contains(choice.id))
                        .map((choice) => choice.certificatePath)
                        .toList(growable: false),
                    includeExternalBundle: includeExternalBundle,
                  ),
                );
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Future<Uint8List?> _pickBinaryFile(List<String> mimeTypes) async {
    File? managedCopy;
    Directory? cacheDirectory;
    try {
      final path = await DocumentIo.pickFile(mimeTypes: mimeTypes);
      if (path == null || path.isEmpty) return null;
      final file = File(path);
      cacheDirectory = await getTemporaryDirectory();
      if (SensitiveFileCache.isManagedImportCopy(file, cacheDirectory)) {
        managedCopy = file;
      }
      return await SensitiveFileCache.readBoundedFile(
        file,
        maxBytes: _maxImportBytes,
      );
    } finally {
      if (managedCopy != null && cacheDirectory != null) {
        await SensitiveFileCache.deleteManagedImportCopy(
          managedCopy,
          cacheDirectory,
        );
      }
    }
  }

  Future<String?> _pickTextFile(List<String> mimeTypes) async {
    Uint8List? bytes;
    try {
      bytes = await _pickBinaryFile(mimeTypes);
      if (bytes == null) return null;
      return utf8.decode(bytes);
    } catch (error) {
      if (mounted) _showMessage(_errorMessage(error), error: true);
      return null;
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  Future<String?> _requestPassword({
    required String title,
    required String description,
    bool confirm = false,
  }) async {
    final formKey = GlobalKey<FormState>();
    final password = TextEditingController();
    final confirmation = TextEditingController();
    var obscure = true;
    return _showControllerDialog<String>(
      controllers: [password, confirmation],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(description),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: password,
                    obscureText: obscure,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setDialogState(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: _validatePassword,
                  ),
                  if (confirm) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: confirmation,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
                      ),
                      validator: (value) => value != password.text
                          ? 'Passwords do not match'
                          : null,
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() == true) {
                  Navigator.pop(dialogContext, password.text);
                }
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_AuthorityDraft?> _showCreateAuthorityDialog() async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController(text: 'FRP Client CA');
    final commonName = TextEditingController(text: 'frp-client-ca');
    final organization = TextEditingController();
    final validDays = TextEditingController(text: '3650');
    final password = TextEditingController();
    final confirmation = TextEditingController();
    var algorithm = 'ecdsa-p256';
    var obscure = true;
    return _showControllerDialog<_AuthorityDraft>(
      controllers: [
        name,
        commonName,
        organization,
        validDays,
        password,
        confirmation,
      ],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Create Certificate Authority'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'CA Name'),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: commonName,
                      decoration: const InputDecoration(
                        labelText: 'Common Name',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: organization,
                      decoration: const InputDecoration(
                        labelText: 'Organization (optional)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: algorithm,
                      decoration: const InputDecoration(labelText: 'Algorithm'),
                      items: _algorithmItems,
                      onChanged: (value) => algorithm = value ?? algorithm,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: validDays,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Validity (days)',
                      ),
                      validator: (value) => _validateDays(value, 365, 7300),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: password,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'CA Password',
                        helperText: 'Used to encrypt the CA private key',
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: _validatePassword,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: confirmation,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Confirm CA Password',
                      ),
                      validator: (value) => value != password.text
                          ? 'Passwords do not match'
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.pop(
                  dialogContext,
                  _AuthorityDraft(
                    name.text.trim(),
                    commonName.text.trim(),
                    organization.text.trim(),
                    algorithm,
                    int.parse(validDays.text),
                    password.text,
                  ),
                );
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_IdentityDraft?> _showCreateIdentityDialog() async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController(text: 'Android Client');
    final commonName = TextEditingController(text: 'android-client');
    final organization = TextEditingController();
    final dnsNames = TextEditingController(text: 'android-client');
    final ipAddresses = TextEditingController();
    var algorithm = 'ecdsa-p256';
    return _showControllerDialog<_IdentityDraft>(
      controllers: [name, commonName, organization, dnsNames, ipAddresses],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Generate Device CSR'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Identity Name',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: commonName,
                      decoration: const InputDecoration(
                        labelText: 'Common Name',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: organization,
                      decoration: const InputDecoration(
                        labelText: 'Organization (optional)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: dnsNames,
                      decoration: const InputDecoration(
                        labelText: 'DNS SANs (comma separated)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: ipAddresses,
                      decoration: const InputDecoration(
                        labelText: 'IP SANs (optional)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: algorithm,
                      decoration: const InputDecoration(labelText: 'Algorithm'),
                      items: _algorithmItems,
                      onChanged: (value) => algorithm = value ?? algorithm,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.pop(
                  dialogContext,
                  _IdentityDraft(
                    name.text.trim(),
                    commonName.text.trim(),
                    organization.text.trim(),
                    algorithm,
                    dnsNames.text,
                    ipAddresses.text,
                  ),
                );
              },
              child: const Text('Generate'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_SignIdentityDraft?> _showSignIdentityDialog(
    ManagedIdentityRecord identity,
  ) async {
    final formKey = GlobalKey<FormState>();
    final password = TextEditingController();
    final validDays = TextEditingController(text: '365');
    var caId = _inventory.authorities.first.id;
    var trustSameCA = false;
    var obscure = true;
    return _showControllerDialog<_SignIdentityDraft>(
      controllers: [password, validDays],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Sign ${identity.name}'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      key: const ValueKey('certificate_signing_ca'),
                      initialValue: caId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Signing CA',
                      ),
                      items: _inventory.authorities
                          .map(
                            (ca) => DropdownMenuItem(
                              value: ca.id,
                              child: Text(
                                ca.selectionLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) => caId = value ?? caId,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: validDays,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Validity (days)',
                      ),
                      validator: (value) => _validateDays(value, 1, 825),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: password,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'CA Password',
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: _validatePassword,
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: trustSameCA,
                      onChanged: (value) =>
                          setDialogState(() => trustSameCA = value ?? false),
                      title: const Text('Also trust this CA for frps'),
                      subtitle: const Text(
                        'Enable only when the same CA signed the server certificate.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.pop(
                  dialogContext,
                  _SignIdentityDraft(
                    caId,
                    password.text,
                    int.parse(validDays.text),
                    trustSameCA,
                  ),
                );
              },
              child: const Text('Sign'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_SignCSRDraft?> _showSignCSRDialog(
    CertificateAuthorityRecord authority,
    CSRInspection inspection,
  ) async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController();
    final validDays = TextEditingController(text: '365');
    final password = TextEditingController();
    var role = 'client';
    var obscure = true;
    var showServerSANError = false;
    return _showControllerDialog<_SignCSRDraft>(
      controllers: [name, validDays, password],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Sign CSR with ${authority.name}'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Verified CSR details (read-only)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    _detailLine('Subject', inspection.subject),
                    _detailLine(
                      'Public key',
                      '${inspection.publicKeyAlgorithm} '
                          '(${inspection.publicKeyBits} bits)',
                    ),
                    _detailLine('CSR signature', inspection.signatureAlgorithm),
                    if (inspection.dnsNames.isNotEmpty)
                      _detailLine('DNS SANs', inspection.dnsNames.join(', ')),
                    if (inspection.ipAddresses.isNotEmpty)
                      _detailLine('IP SANs', inspection.ipAddresses.join(', ')),
                    if (inspection.emailAddresses.isNotEmpty)
                      _detailLine(
                        'Email SANs',
                        inspection.emailAddresses.join(', '),
                      ),
                    if (inspection.uris.isNotEmpty)
                      _detailLine('URI SANs', inspection.uris.join(', ')),
                    _detailLine(
                      'Fingerprint',
                      inspection.shortFingerprint,
                      monospace: true,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Record Name (optional)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: role,
                      decoration: const InputDecoration(labelText: 'Role'),
                      items: const [
                        DropdownMenuItem(
                          value: 'client',
                          child: Text('Client authentication'),
                        ),
                        DropdownMenuItem(
                          value: 'server',
                          child: Text('Server authentication'),
                        ),
                      ],
                      onChanged: (value) => setDialogState(() {
                        role = value ?? role;
                        showServerSANError = false;
                      }),
                    ),
                    if (showServerSANError)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'This CSR has no DNS or IP SAN and cannot be signed '
                          'as a server certificate.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: validDays,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Validity (days)',
                      ),
                      validator: (value) => _validateDays(value, 1, 825),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: password,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'CA Password',
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: _validatePassword,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                if (role == 'server' && !inspection.canSignAsServer) {
                  setDialogState(() => showServerSANError = true);
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  _SignCSRDraft(
                    name.text.trim(),
                    role,
                    int.parse(validDays.text),
                    password.text,
                  ),
                );
              },
              child: const Text('Sign'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_ServerCertificateDraft?> _showGenerateServerDialog(
    CertificateAuthorityRecord authority,
  ) async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController(text: 'FRPS Server');
    final commonName = TextEditingController(text: 'frps.example.com');
    final organization = TextEditingController();
    final dnsNames = TextEditingController(text: 'frps.example.com');
    final ipAddresses = TextEditingController();
    final validDays = TextEditingController(text: '365');
    final password = TextEditingController();
    var algorithm = 'ecdsa-p256';
    var obscure = true;
    return _showControllerDialog<_ServerCertificateDraft>(
      controllers: [
        name,
        commonName,
        organization,
        dnsNames,
        ipAddresses,
        validDays,
        password,
      ],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Generate frps Certificate with ${authority.name}'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Record Name',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: commonName,
                      decoration: const InputDecoration(
                        labelText: 'Common Name',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: organization,
                      decoration: const InputDecoration(
                        labelText: 'Organization (optional)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: dnsNames,
                      decoration: const InputDecoration(
                        labelText: 'DNS SANs (comma separated)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: ipAddresses,
                      decoration: const InputDecoration(
                        labelText: 'IP SANs (comma separated)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: algorithm,
                      decoration: const InputDecoration(labelText: 'Algorithm'),
                      items: _algorithmItems,
                      onChanged: (value) => algorithm = value ?? algorithm,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: validDays,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Validity (days)',
                      ),
                      validator: (value) => _validateDays(value, 1, 825),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: password,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'CA Password',
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: _validatePassword,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                if (_splitValues(dnsNames.text).isEmpty &&
                    _splitValues(ipAddresses.text).isEmpty) {
                  _showMessage(
                    'Enter at least one DNS or IP SAN for the server.',
                    error: true,
                  );
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  _ServerCertificateDraft(
                    name.text.trim(),
                    commonName.text.trim(),
                    organization.text.trim(),
                    algorithm,
                    dnsNames.text,
                    ipAddresses.text,
                    int.parse(validDays.text),
                    password.text,
                  ),
                );
              },
              child: const Text('Generate'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_ServerBinding?> _showServerBindingDialog(
    ManagedIdentityRecord identity,
  ) async {
    final formKey = GlobalKey<FormState>();
    var serverId = appState.selectedServerId;
    if (!appState.servers.any((server) => server.serverId == serverId)) {
      serverId = appState.servers.first.serverId;
    }
    final initialServer = appState.servers.firstWhere(
      (server) => server.serverId == serverId,
    );
    final serverName = TextEditingController(
      text: initialServer.tlsServerName.isNotEmpty
          ? initialServer.tlsServerName
          : initialServer.serverAddr,
    );
    return _showControllerDialog<_ServerBinding>(
      controllers: [serverName],
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Use ${identity.name}'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: serverId,
                    decoration: const InputDecoration(
                      labelText: 'Server Config',
                    ),
                    items: appState.servers
                        .map(
                          (server) => DropdownMenuItem(
                            value: server.serverId,
                            child: Text(server.name),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        serverId = value;
                        final server = appState.servers.firstWhere(
                          (entry) => entry.serverId == value,
                        );
                        serverName.text = server.tlsServerName.isNotEmpty
                            ? server.tlsServerName
                            : server.serverAddr;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: serverName,
                    decoration: const InputDecoration(
                      labelText: 'TLS Server Name',
                      helperText: 'Must match a DNS or IP SAN in server.crt',
                    ),
                    validator: _required,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.pop(
                  dialogContext,
                  _ServerBinding(serverId, serverName.text.trim()),
                );
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Future<T?> _showControllerDialog<T>({
    required List<TextEditingController> controllers,
    required WidgetBuilder builder,
  }) => showDialog<T>(
    context: context,
    builder: (dialogContext) => _ControllerOwner(
      controllers: controllers,
      child: builder(dialogContext),
    ),
  );

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  String _errorMessage(Object error) => switch (error) {
    CertificateEngineException exception => exception.message,
    FormatException exception => exception.message.toString(),
    _ => 'Certificate operation failed: $error',
  };

  Color _statusColor(String status) => switch (status) {
    'ready' || 'valid' => const Color(0xFF4CAF50),
    'csr_ready' || 'certificate_installed' => const Color(0xFFFF9800),
    'expiring' => const Color(0xFFFF9800),
    'expired' ||
    'invalid' ||
    'not_yet_valid' ||
    'trusted_ca_expired' ||
    'trusted_ca_not_yet_valid' ||
    'trusted_ca_invalid' => Theme.of(context).colorScheme.error,
    _ => Theme.of(context).colorScheme.onSurfaceVariant,
  };

  String _statusLabel(String status) => switch (status) {
    'ready' => 'Ready for mutual TLS',
    'valid' => 'Valid',
    'csr_ready' => 'CSR ready',
    'certificate_installed' => 'Trusted server CA required',
    'expiring' => 'Expires within 30 days',
    'expired' => 'Expired',
    'not_yet_valid' => 'Not valid yet',
    'invalid' => 'Invalid',
    'trusted_ca_expired' => 'Trusted server CA expired',
    'trusted_ca_not_yet_valid' => 'Trusted server CA not valid yet',
    'trusted_ca_invalid' => 'Trusted server CA invalid',
    _ => status.replaceAll('_', ' '),
  };

  String _formatDate(DateTime? date) {
    if (date == null) return '—';
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  static String? _validateDays(String? value, int minimum, int maximum) {
    final parsed = int.tryParse(value ?? '');
    return parsed == null || parsed < minimum || parsed > maximum
        ? 'Use $minimum–$maximum days'
        : null;
  }

  static String? _validatePassword(String? value) {
    final length = value?.length ?? 0;
    if (length < BackupCrypto.minPasswordLength) {
      return 'Use at least 12 characters';
    }
    if (length > BackupCrypto.maxPasswordLength) {
      return 'Use at most 1024 characters';
    }
    return null;
  }

  static List<String> _splitValues(String value) => value
      .split(RegExp(r'[,\n]'))
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);

  static String _safeFileName(String value, {required String suffix}) {
    const maxFileNameLength = 128;
    var safe = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    if (safe.isEmpty) safe = 'frp-certificate';
    final maxBaseLength = maxFileNameLength - suffix.length;
    if (safe.length > maxBaseLength) {
      safe = safe.substring(0, maxBaseLength);
    }
    return '$safe$suffix';
  }

  static String _algorithmLabel(String value) => switch (value) {
    'ecdsa-p256' || 'ecdsa-p-256' => 'ECDSA P-256',
    'rsa-2048' => 'RSA 2048',
    _ => value,
  };

  static const _algorithmItems = [
    DropdownMenuItem(value: 'ecdsa-p256', child: Text('ECDSA P-256')),
    DropdownMenuItem(value: 'rsa-2048', child: Text('RSA 2048')),
  ];
}

class _ControllerOwner extends StatefulWidget {
  const _ControllerOwner({required this.controllers, required this.child});

  final List<TextEditingController> controllers;
  final Widget child;

  @override
  State<_ControllerOwner> createState() => _ControllerOwnerState();
}

class _ControllerOwnerState extends State<_ControllerOwner> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AuthorityDraft {
  const _AuthorityDraft(
    this.name,
    this.commonName,
    this.organization,
    this.algorithm,
    this.validDays,
    this.password,
  );

  final String name;
  final String commonName;
  final String organization;
  final String algorithm;
  final int validDays;
  final String password;
}

class _IdentityDraft {
  const _IdentityDraft(
    this.name,
    this.commonName,
    this.organization,
    this.algorithm,
    this.dnsNames,
    this.ipAddresses,
  );

  final String name;
  final String commonName;
  final String organization;
  final String algorithm;
  final String dnsNames;
  final String ipAddresses;
}

class _SignIdentityDraft {
  const _SignIdentityDraft(
    this.caId,
    this.password,
    this.validDays,
    this.useCaAsTrustedServer,
  );

  final String caId;
  final String password;
  final int validDays;
  final bool useCaAsTrustedServer;
}

class _SignCSRDraft {
  const _SignCSRDraft(this.name, this.role, this.validDays, this.password);

  final String name;
  final String role;
  final int validDays;
  final String password;
}

class _ServerCertificateDraft {
  const _ServerCertificateDraft(
    this.name,
    this.commonName,
    this.organization,
    this.algorithm,
    this.dnsNames,
    this.ipAddresses,
    this.validDays,
    this.password,
  );

  final String name;
  final String commonName;
  final String organization;
  final String algorithm;
  final String dnsNames;
  final String ipAddresses;
  final int validDays;
  final String password;
}

class _ServerBinding {
  const _ServerBinding(this.serverId, this.serverName);

  final String serverId;
  final String serverName;
}

class _TrustedClientCAChoice {
  const _TrustedClientCAChoice({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.certificatePath,
  });

  final String id;
  final String title;
  final String subtitle;
  final String certificatePath;
}

class _TrustedClientCASelection {
  const _TrustedClientCASelection({
    required this.certificatePaths,
    required this.includeExternalBundle,
  });

  final List<String> certificatePaths;
  final bool includeExternalBundle;
}
