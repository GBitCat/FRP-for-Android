package main

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const maxInventoryWarnings = 128

func listInventory(request apiRequest) (inventoryView, error) {
	inventory := inventoryView{
		Authorities: []authorityView{},
		Identities:  []identityView{},
		Issued:      []issuedView{},
		Warnings:    []string{},
	}
	authorityDirs, err := metadataDirectories(request.Root, "authorities")
	if err != nil {
		return inventory, err
	}
	for _, directory := range authorityDirs {
		view, viewErr := authorityViewFromDir(directory)
		if viewErr != nil {
			appendInventoryWarning(&inventory, directory, viewErr)
			continue
		}
		inventory.Authorities = append(inventory.Authorities, view)
	}
	identityDirs, err := metadataDirectories(request.Root, "identities")
	if err != nil {
		return inventory, err
	}
	for _, directory := range identityDirs {
		view, viewErr := identityViewFromDir(directory)
		if viewErr != nil {
			appendInventoryWarning(&inventory, directory, viewErr)
			continue
		}
		inventory.Identities = append(inventory.Identities, view)
	}
	issuedDirs, err := metadataDirectories(request.Root, "issued")
	if err != nil {
		return inventory, err
	}
	for _, directory := range issuedDirs {
		view, viewErr := issuedViewFromDir(request.Root, directory)
		if viewErr != nil {
			appendInventoryWarning(&inventory, directory, viewErr)
			continue
		}
		inventory.Issued = append(inventory.Issued, view)
	}
	return inventory, nil
}

func appendInventoryWarning(inventory *inventoryView, directory string, err error) {
	if len(inventory.Warnings) >= maxInventoryWarnings {
		return
	}
	if len(inventory.Warnings) == maxInventoryWarnings-1 {
		inventory.Warnings = append(
			inventory.Warnings,
			"additional damaged certificate records were omitted",
		)
		return
	}
	inventory.Warnings = append(inventory.Warnings, formatWarning(directory, err))
}

func createAuthority(request apiRequest) (authorityView, error) {
	name, err := validateDisplayText(request.Name, "CA name", true)
	if err != nil {
		return authorityView{}, err
	}
	commonName, err := validateDisplayText(request.CommonName, "CA common name", true)
	if err != nil {
		return authorityView{}, err
	}
	organization, err := validateDisplayText(request.Organization, "organization", false)
	if err != nil {
		return authorityView{}, err
	}
	validDays, err := normalizeValidity(request.ValidDays, 3650, 365, 7300)
	if err != nil {
		return authorityView{}, err
	}
	if err := ensureManagedRecordCapacity(request.Root, "authorities"); err != nil {
		return authorityView{}, err
	}
	id, err := newManagedID("ca")
	if err != nil {
		return authorityView{}, err
	}
	target, err := managedDir(request.Root, "authorities", id, "ca")
	if err != nil {
		return authorityView{}, err
	}
	staging, err := createStagingDir(request.Root, "authorities", id)
	if err != nil {
		return authorityView{}, err
	}
	defer os.RemoveAll(staging)

	privateKey, certificatePEM, certificate, algorithm, err := createCA(
		commonName,
		organization,
		request.Algorithm,
		validDays,
	)
	if err != nil {
		return authorityView{}, err
	}
	defer clear(privateKey)
	fingerprint := certificateFingerprint(certificate)
	encryptedKey, err := encryptCAKey(privateKey, request.Password, fingerprint)
	if err != nil {
		return authorityView{}, err
	}
	metadata := authorityMetadata{
		ID:          id,
		Name:        name,
		CommonName:  commonName,
		Algorithm:   algorithm,
		CreatedAt:   time.Now().UTC().Format(time.RFC3339),
		NotAfter:    certificate.NotAfter.UTC().Format(time.RFC3339),
		Fingerprint: fingerprint,
	}
	if err := atomicWrite(filepath.Join(staging, "ca.crt"), certificatePEM, 0o644); err != nil {
		return authorityView{}, err
	}
	if err := atomicWrite(filepath.Join(staging, "ca.key.enc"), encryptedKey, 0o600); err != nil {
		return authorityView{}, err
	}
	if err := writeJSON(filepath.Join(staging, "metadata.json"), metadata); err != nil {
		return authorityView{}, err
	}
	if err := commitStagingDir(staging, target); err != nil {
		return authorityView{}, err
	}
	return authorityViewFromDir(target)
}

func importAuthorityRecovery(request apiRequest) (authorityView, error) {
	name, err := validateDisplayText(request.Name, "CA name", false)
	if err != nil {
		return authorityView{}, err
	}
	if err := ensureManagedRecordCapacity(request.Root, "authorities"); err != nil {
		return authorityView{}, err
	}
	certificatePEM := []byte(request.CertificatePem)
	certificates, err := parseCertificatesPEM(certificatePEM)
	if err != nil || len(certificates) != 1 {
		return authorityView{}, problem("INVALID_CA", "CA recovery certificate is invalid")
	}
	certificate := certificates[0]
	if err := validateCACertificatePolicy(certificate); err != nil {
		return authorityView{}, err
	}
	commonName, err := validateDisplayText(certificate.Subject.CommonName, "CA common name", false)
	if err != nil {
		return authorityView{}, problem("INVALID_CA", "recovery certificate common name is invalid")
	}
	now := time.Now().UTC()
	if now.Before(certificate.NotBefore) {
		return authorityView{}, problem("CA_NOT_YET_VALID", "recovery CA certificate is not valid yet")
	}
	if !now.Before(certificate.NotAfter) {
		return authorityView{}, problem("CA_EXPIRED", "recovery CA certificate has expired")
	}
	fingerprint := certificateFingerprint(certificate)
	key, err := decryptCAKey([]byte(request.EncryptedKeyPayload), request.Password, fingerprint)
	if err != nil {
		return authorityView{}, err
	}
	if !publicKeysEqual(certificate.PublicKey, key.Public()) {
		return authorityView{}, problem("INVALID_CA_KEY", "recovery CA key does not match its certificate")
	}
	if name == "" {
		name = commonName
	}
	if name == "" {
		name = "Imported CA"
	}
	id, err := newManagedID("ca")
	if err != nil {
		return authorityView{}, err
	}
	target, err := managedDir(request.Root, "authorities", id, "ca")
	if err != nil {
		return authorityView{}, err
	}
	staging, err := createStagingDir(request.Root, "authorities", id)
	if err != nil {
		return authorityView{}, err
	}
	defer os.RemoveAll(staging)
	metadata := authorityMetadata{
		ID:          id,
		Name:        name,
		CommonName:  commonName,
		Algorithm:   publicKeyAlgorithm(certificate.PublicKey),
		CreatedAt:   time.Now().UTC().Format(time.RFC3339),
		NotAfter:    certificate.NotAfter.UTC().Format(time.RFC3339),
		Fingerprint: fingerprint,
	}
	if err := atomicWrite(filepath.Join(staging, "ca.crt"), certificatePEM, 0o644); err != nil {
		return authorityView{}, err
	}
	if err := atomicWrite(
		filepath.Join(staging, "ca.key.enc"),
		[]byte(request.EncryptedKeyPayload),
		0o600,
	); err != nil {
		return authorityView{}, err
	}
	if err := writeJSON(filepath.Join(staging, "metadata.json"), metadata); err != nil {
		return authorityView{}, err
	}
	if err := commitStagingDir(staging, target); err != nil {
		return authorityView{}, err
	}
	return authorityViewFromDir(target)
}

func deleteAuthority(request apiRequest) (map[string]any, error) {
	if err := validateManagedID(request.ID, "ca"); err != nil {
		return nil, err
	}
	if !request.Force {
		issuedDirs, err := metadataDirectories(request.Root, "issued")
		if err != nil {
			return nil, err
		}
		for _, directory := range issuedDirs {
			var metadata issuedMetadata
			if readJSON(filepath.Join(directory, "metadata.json"), &metadata) == nil && metadata.CAID == request.ID {
				return nil, problem("CA_IN_USE", "CA has issued certificate records; confirm forced deletion")
			}
		}
	}
	if err := safeRemoveManaged(request.Root, "authorities", request.ID, "ca"); err != nil {
		return nil, err
	}
	return map[string]any{"deleted": request.ID}, nil
}

func createIdentity(request apiRequest) (identityView, error) {
	name, err := validateDisplayText(request.Name, "identity name", true)
	if err != nil {
		return identityView{}, err
	}
	commonName, err := validateDisplayText(request.CommonName, "identity common name", true)
	if err != nil {
		return identityView{}, err
	}
	organization, err := validateDisplayText(request.Organization, "organization", false)
	if err != nil {
		return identityView{}, err
	}
	dnsNames, ipAddresses, err := validateNames(request.DNSNames, request.IPAddresses)
	if err != nil {
		return identityView{}, err
	}
	if err := ensureManagedRecordCapacity(request.Root, "identities"); err != nil {
		return identityView{}, err
	}
	id, err := newManagedID("id")
	if err != nil {
		return identityView{}, err
	}
	target, err := managedDir(request.Root, "identities", id, "id")
	if err != nil {
		return identityView{}, err
	}
	staging, err := createStagingDir(request.Root, "identities", id)
	if err != nil {
		return identityView{}, err
	}
	defer os.RemoveAll(staging)
	privateKey, csrPEM, _, algorithm, err := createCSR(
		commonName,
		organization,
		request.Algorithm,
		dnsNames,
		ipAddresses,
	)
	if err != nil {
		return identityView{}, err
	}
	defer clear(privateKey)
	metadata := identityMetadata{
		ID:          id,
		Name:        name,
		CommonName:  commonName,
		Algorithm:   algorithm,
		DNSNames:    append([]string(nil), dnsNames...),
		IPAddresses: canonicalIPStrings(ipAddresses),
		CreatedAt:   time.Now().UTC().Format(time.RFC3339),
	}
	if err := atomicWrite(filepath.Join(staging, "client.key"), privateKey, 0o600); err != nil {
		return identityView{}, err
	}
	if err := atomicWrite(filepath.Join(staging, "client.csr"), csrPEM, 0o644); err != nil {
		return identityView{}, err
	}
	if err := writeJSON(filepath.Join(staging, "metadata.json"), metadata); err != nil {
		return identityView{}, err
	}
	if err := commitStagingDir(staging, target); err != nil {
		return identityView{}, err
	}
	return identityViewFromDir(target)
}

func deleteIdentity(request apiRequest) (map[string]any, error) {
	if err := safeRemoveManaged(request.Root, "identities", request.ID, "id"); err != nil {
		return nil, err
	}
	return map[string]any{"deleted": request.ID}, nil
}

func signIdentity(request apiRequest) (identityView, error) {
	validDays, err := normalizeValidity(request.ValidDays, 365, 1, 825)
	if err != nil {
		return identityView{}, err
	}
	directory, err := managedDir(request.Root, "identities", request.IdentityID, "id")
	if err != nil {
		return identityView{}, err
	}
	var identity identityMetadata
	if err := readJSON(filepath.Join(directory, "metadata.json"), &identity); err != nil {
		return identityView{}, err
	}
	keyPEM, err := readLimitedFile(filepath.Join(directory, "client.key"))
	if err != nil {
		return identityView{}, err
	}
	defer clear(keyPEM)
	key, err := parsePrivateKeyPEM(keyPEM)
	if err != nil {
		return identityView{}, err
	}
	csrPEM, err := readLimitedFile(filepath.Join(directory, "client.csr"))
	if err != nil {
		return identityView{}, err
	}
	csr, err := parseCSRPEM(csrPEM)
	if err != nil {
		return identityView{}, err
	}
	_, ca, caKey, err := loadAuthority(request.Root, request.CAID, request.Password)
	if err != nil {
		return identityView{}, err
	}
	certificatePEM, certificate, err := issueCertificate(csr, ca, caKey, "client", validDays)
	if err != nil {
		return identityView{}, err
	}
	if err := validateLeafCertificate(certificate, key, "client"); err != nil {
		return identityView{}, err
	}
	updates := map[string]managedFileUpdate{
		"client.crt": {Data: certificatePEM, Mode: 0o644},
	}
	if request.UseCAAsTrustedServer {
		caPEM, err := readLimitedFile(filepath.Join(request.Root, "authorities", request.CAID, "ca.crt"))
		if err != nil {
			return identityView{}, err
		}
		updates["trusted-server-ca.crt"] = managedFileUpdate{Data: caPEM, Mode: 0o644}
	}
	identityStaging, identityTarget, err := stageManagedDirectoryUpdate(
		request.Root,
		"identities",
		request.IdentityID,
		"id",
		updates,
	)
	if err != nil {
		return identityView{}, err
	}
	defer os.RemoveAll(identityStaging)
	issued, err := prepareIssuedRecord(
		request.Root,
		request.CAID,
		identity.Name,
		"client",
		certificatePEM,
		certificate,
		nil,
		csrPEM,
	)
	if err != nil {
		return identityView{}, err
	}
	defer issued.discard()
	// Persist the issuance audit record before activating the
	// identity. This is the cross-directory commit point: a crash between the
	// two commits may leave an issued-but-not-installed certificate, but can
	// never leave an installed identity without its issuance record.
	if _, err := issued.commit(); err != nil {
		return identityView{}, err
	}
	replacement, err := beginManagedDirectoryReplacement(identityStaging, identityTarget)
	if err != nil {
		// A nil replacement means begin restored the original identity. If it
		// could not prove that restoration, retain the audit record rather than
		// risk an activated certificate with no issuance history.
		if replacement == nil {
			_ = issued.rollbackCommitted()
		}
		return identityView{}, err
	}
	view, err := identityViewFromDir(directory)
	if err != nil {
		rollbackSignedIdentity(replacement, issued)
		return identityView{}, err
	}
	if err := replacement.finalize(); err != nil {
		rollbackSignedIdentity(replacement, issued)
		return identityView{}, err
	}
	return view, nil
}

func rollbackSignedIdentity(
	replacement *managedDirectoryReplacement,
	issued *preparedIssuedRecord,
) {
	if replacement.rollback() == nil {
		_ = issued.rollbackCommitted()
	}
}

func installIdentity(request apiRequest) (identityView, error) {
	if strings.TrimSpace(request.CertificatePem) == "" {
		return identityView{}, problem("INVALID_CERTIFICATE", "signed client certificate is required")
	}
	directory, err := managedDir(request.Root, "identities", request.IdentityID, "id")
	if err != nil {
		return identityView{}, err
	}
	keyPEM, err := readLimitedFile(filepath.Join(directory, "client.key"))
	if err != nil {
		return identityView{}, err
	}
	defer clear(keyPEM)
	key, err := parsePrivateKeyPEM(keyPEM)
	if err != nil {
		return identityView{}, err
	}
	csrPEM, err := readLimitedFile(filepath.Join(directory, "client.csr"))
	if err != nil {
		return identityView{}, err
	}
	csr, err := parseCSRPEM(csrPEM)
	if err != nil {
		return identityView{}, err
	}
	certificatePEM := []byte(request.CertificatePem)
	certificates, err := parseCertificatesPEM(certificatePEM)
	if err != nil {
		return identityView{}, err
	}
	if err := validateLeafCertificate(certificates[0], key, "client"); err != nil {
		return identityView{}, err
	}
	if !csrMatchesCertificate(csr, certificates[0]) {
		return identityView{}, problem(
			"CSR_CERT_MISMATCH",
			"signed client certificate does not preserve the managed CSR subject and SANs",
		)
	}
	updates := map[string]managedFileUpdate{
		"client.crt": {Data: certificatePEM, Mode: 0o644},
	}
	if strings.TrimSpace(request.TrustedCAPem) != "" {
		if _, err := validateCABundle([]byte(request.TrustedCAPem)); err != nil {
			return identityView{}, err
		}
		updates["trusted-server-ca.crt"] = managedFileUpdate{
			Data: []byte(request.TrustedCAPem),
			Mode: 0o644,
		}
	}
	return updateIdentityDirectory(request.Root, request.IdentityID, updates)
}

func installTrustedCA(request apiRequest) (identityView, error) {
	if strings.TrimSpace(request.TrustedCAPem) == "" {
		return identityView{}, problem("INVALID_CA", "trusted server CA certificate is required")
	}
	if _, err := validateCABundle([]byte(request.TrustedCAPem)); err != nil {
		return identityView{}, err
	}
	return updateIdentityDirectory(request.Root, request.IdentityID, map[string]managedFileUpdate{
		"trusted-server-ca.crt": {Data: []byte(request.TrustedCAPem), Mode: 0o644},
	})
}

func updateIdentityDirectory(
	root, identityID string,
	updates map[string]managedFileUpdate,
) (identityView, error) {
	staging, target, err := stageManagedDirectoryUpdate(root, "identities", identityID, "id", updates)
	if err != nil {
		return identityView{}, err
	}
	defer os.RemoveAll(staging)
	replacement, err := beginManagedDirectoryReplacement(staging, target)
	if err != nil {
		return identityView{}, err
	}
	view, err := identityViewFromDir(target)
	if err != nil {
		_ = replacement.rollback()
		return identityView{}, err
	}
	if err := replacement.finalize(); err != nil {
		_ = replacement.rollback()
		return identityView{}, err
	}
	return view, nil
}

func inspectCSR(request apiRequest) (csrInspectionView, error) {
	csr, err := parseCSRPEM([]byte(request.CSRPem))
	if err != nil {
		return csrInspectionView{}, err
	}
	algorithm, bits, err := validateCSRPolicy(csr, "")
	if err != nil {
		return csrInspectionView{}, err
	}
	uriStrings := make([]string, 0, len(csr.URIs))
	for _, uri := range csr.URIs {
		uriStrings = append(uriStrings, uri.String())
	}
	return csrInspectionView{
		Subject:            csr.Subject.String(),
		CommonName:         csr.Subject.CommonName,
		Organizations:      append([]string(nil), csr.Subject.Organization...),
		DNSNames:           append([]string(nil), csr.DNSNames...),
		IPAddresses:        canonicalIPStrings(csr.IPAddresses),
		EmailAddresses:     append([]string(nil), csr.EmailAddresses...),
		URIs:               uriStrings,
		PublicKeyAlgorithm: algorithm,
		PublicKeyBits:      bits,
		SignatureAlgorithm: csr.SignatureAlgorithm.String(),
		Fingerprint:        sha256Fingerprint(csr.Raw),
		CanSignAsServer:    len(csr.DNSNames) > 0 || len(csr.IPAddresses) > 0,
	}, nil
}

func validateCABundleRequest(request apiRequest) (map[string]any, error) {
	certificates, err := validateCABundle([]byte(request.TrustedCAPem))
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"count":        len(certificates),
		"certificates": trustedCAViews(certificates),
	}, nil
}

func signExternalCSR(request apiRequest) (issuedView, error) {
	validDays, err := normalizeValidity(request.ValidDays, 365, 1, 825)
	if err != nil {
		return issuedView{}, err
	}
	csr, err := parseCSRPEM([]byte(request.CSRPem))
	if err != nil {
		return issuedView{}, err
	}
	if _, _, err := validateCSRPolicy(csr, request.Role); err != nil {
		return issuedView{}, err
	}
	name, err := validateDisplayText(request.Name, "certificate name", false)
	if err != nil {
		return issuedView{}, err
	}
	if name == "" {
		name = csr.Subject.CommonName
	}
	if name == "" {
		name = "Issued certificate"
	}
	name, err = validateDisplayText(name, "certificate name", true)
	if err != nil {
		return issuedView{}, err
	}
	_, ca, caKey, err := loadAuthority(request.Root, request.CAID, request.Password)
	if err != nil {
		return issuedView{}, err
	}
	certificatePEM, certificate, err := issueCertificate(csr, ca, caKey, request.Role, validDays)
	if err != nil {
		return issuedView{}, err
	}
	return createIssuedRecord(
		request.Root,
		request.CAID,
		name,
		request.Role,
		certificatePEM,
		certificate,
		nil,
		[]byte(request.CSRPem),
	)
}

func generateServerCertificate(request apiRequest) (issuedView, error) {
	name, err := validateDisplayText(request.Name, "certificate name", true)
	if err != nil {
		return issuedView{}, err
	}
	commonName, err := validateDisplayText(request.CommonName, "server common name", true)
	if err != nil {
		return issuedView{}, err
	}
	organization, err := validateDisplayText(request.Organization, "organization", false)
	if err != nil {
		return issuedView{}, err
	}
	dnsNames, ipAddresses, err := validateNames(request.DNSNames, request.IPAddresses)
	if err != nil {
		return issuedView{}, err
	}
	if len(dnsNames) == 0 && len(ipAddresses) == 0 {
		return issuedView{}, problem("INVALID_SAN", "server certificate requires at least one DNS or IP SAN")
	}
	validDays, err := normalizeValidity(request.ValidDays, 365, 1, 825)
	if err != nil {
		return issuedView{}, err
	}
	privateKey, csrPEM, csr, _, err := createCSR(
		commonName,
		organization,
		request.Algorithm,
		dnsNames,
		ipAddresses,
	)
	if err != nil {
		return issuedView{}, err
	}
	defer clear(privateKey)
	_, ca, caKey, err := loadAuthority(request.Root, request.CAID, request.Password)
	if err != nil {
		return issuedView{}, err
	}
	certificatePEM, certificate, err := issueCertificate(csr, ca, caKey, "server", validDays)
	if err != nil {
		return issuedView{}, err
	}
	return createIssuedRecord(
		request.Root,
		request.CAID,
		name,
		"server",
		certificatePEM,
		certificate,
		privateKey,
		csrPEM,
	)
}

func deleteIssuedCertificate(request apiRequest) (map[string]any, error) {
	if err := safeRemoveManaged(request.Root, "issued", request.ID, "cert"); err != nil {
		return nil, err
	}
	return map[string]any{"deleted": request.ID}, nil
}

func createIssuedRecord(
	root, caID, name, role string,
	certificatePEM []byte,
	certificate *x509.Certificate,
	privateKeyPEM, csrPEM []byte,
) (issuedView, error) {
	prepared, err := prepareIssuedRecord(
		root,
		caID,
		name,
		role,
		certificatePEM,
		certificate,
		privateKeyPEM,
		csrPEM,
	)
	if err != nil {
		return issuedView{}, err
	}
	defer prepared.discard()
	return prepared.commit()
}

type preparedIssuedRecord struct {
	root      string
	id        string
	staging   string
	target    string
	committed bool
}

func prepareIssuedRecord(
	root, caID, name, role string,
	certificatePEM []byte,
	certificate *x509.Certificate,
	privateKeyPEM, csrPEM []byte,
) (*preparedIssuedRecord, error) {
	if err := ensureManagedRecordCapacity(root, "issued"); err != nil {
		return nil, err
	}
	id, err := newManagedID("cert")
	if err != nil {
		return nil, err
	}
	target, err := managedDir(root, "issued", id, "cert")
	if err != nil {
		return nil, err
	}
	staging, err := createStagingDir(root, "issued", id)
	if err != nil {
		return nil, err
	}
	prepared := &preparedIssuedRecord{root: root, id: id, staging: staging, target: target}
	failed := true
	defer func() {
		if failed {
			prepared.discard()
		}
	}()
	metadata := issuedMetadata{
		ID:            id,
		CAID:          caID,
		Name:          name,
		Role:          strings.ToLower(role),
		Subject:       certificate.Subject.String(),
		SerialNumber:  certificate.SerialNumber.Text(16),
		IssuedAt:      time.Now().UTC().Format(time.RFC3339),
		NotAfter:      certificate.NotAfter.UTC().Format(time.RFC3339),
		Fingerprint:   certificateFingerprint(certificate),
		HasPrivateKey: len(privateKeyPEM) > 0,
	}
	if err := atomicWrite(filepath.Join(staging, "certificate.crt"), certificatePEM, 0o644); err != nil {
		return nil, err
	}
	caPEM, err := readLimitedFile(filepath.Join(root, "authorities", caID, "ca.crt"))
	if err != nil {
		return nil, err
	}
	if err := atomicWrite(filepath.Join(staging, "ca.crt"), caPEM, 0o644); err != nil {
		return nil, err
	}
	if len(privateKeyPEM) > 0 {
		if err := atomicWrite(filepath.Join(staging, "private.key"), privateKeyPEM, 0o600); err != nil {
			return nil, err
		}
	}
	if len(csrPEM) > 0 {
		if err := atomicWrite(filepath.Join(staging, "request.csr"), csrPEM, 0o644); err != nil {
			return nil, err
		}
	}
	if err := writeJSON(filepath.Join(staging, "metadata.json"), metadata); err != nil {
		return nil, err
	}
	if err := syncDirectory(staging); err != nil {
		return nil, err
	}
	failed = false
	return prepared, nil
}

func (prepared *preparedIssuedRecord) commit() (issuedView, error) {
	if prepared == nil || prepared.committed {
		return issuedView{}, problem("INTERNAL_ERROR", "issued certificate transaction is invalid")
	}
	if err := commitStagingDir(prepared.staging, prepared.target); err != nil {
		return issuedView{}, err
	}
	prepared.committed = true
	view, err := issuedViewFromDir(prepared.root, prepared.target)
	if err != nil {
		_ = prepared.rollbackCommitted()
		return issuedView{}, err
	}
	return view, nil
}

func (prepared *preparedIssuedRecord) discard() {
	if prepared != nil && !prepared.committed {
		_ = os.RemoveAll(prepared.staging)
	}
}

func (prepared *preparedIssuedRecord) rollbackCommitted() error {
	if prepared == nil || !prepared.committed {
		return nil
	}
	if err := safeRemoveManaged(prepared.root, "issued", prepared.id, "cert"); err != nil {
		return err
	}
	prepared.committed = false
	return nil
}

func authorityViewFromDir(directory string) (authorityView, error) {
	var metadata authorityMetadata
	if err := readJSON(filepath.Join(directory, "metadata.json"), &metadata); err != nil {
		return authorityView{}, err
	}
	if err := validateManagedDirectoryID(directory, metadata.ID, "ca"); err != nil {
		return authorityView{}, err
	}
	certificatePath := filepath.Join(directory, "ca.crt")
	certificatePEM, err := readLimitedFile(certificatePath)
	if err != nil {
		return authorityView{}, err
	}
	certificates, err := parseCertificatesPEM(certificatePEM)
	if err != nil || len(certificates) != 1 {
		return authorityView{}, problem("INVALID_CA", "managed CA certificate is invalid")
	}
	certificate := certificates[0]
	if err := validateCACertificatePolicy(certificate); err != nil {
		return authorityView{}, err
	}
	if metadata.Fingerprint != certificateFingerprint(certificate) {
		return authorityView{}, problem("INVALID_CA", "managed CA certificate fingerprint changed")
	}
	if metadata.CommonName != certificate.Subject.CommonName ||
		metadata.Algorithm != publicKeyAlgorithm(certificate.PublicKey) ||
		metadata.NotAfter != certificate.NotAfter.UTC().Format(time.RFC3339) {
		return authorityView{}, problem("INVALID_METADATA", "managed CA metadata does not match its certificate")
	}
	if name, err := validateDisplayText(metadata.Name, "CA name", true); err != nil || name != metadata.Name {
		return authorityView{}, problem("INVALID_METADATA", "managed CA metadata contains an invalid name")
	}
	if commonName, err := validateDisplayText(metadata.CommonName, "CA common name", false); err != nil || commonName != metadata.CommonName {
		return authorityView{}, problem("INVALID_METADATA", "managed CA metadata contains an invalid common name")
	}
	if _, err := time.Parse(time.RFC3339, metadata.CreatedAt); err != nil {
		return authorityView{}, problem("INVALID_METADATA", "managed CA creation time is invalid")
	}
	encryptedKeyPath := filepath.Join(directory, "ca.key.enc")
	encryptedKey, err := readLimitedFile(encryptedKeyPath)
	if err != nil {
		return authorityView{}, err
	}
	defer clear(encryptedKey)
	if err := validateEncryptedCAKey(encryptedKey, metadata.Fingerprint); err != nil {
		return authorityView{}, err
	}
	status := validityStatus(certificate.NotBefore, certificate.NotAfter)
	return authorityView{
		authorityMetadata: metadata,
		CertificatePath:   certificatePath,
		EncryptedKeyPath:  encryptedKeyPath,
		Status:            status,
	}, nil
}

func identityViewFromDir(directory string) (identityView, error) {
	var metadata identityMetadata
	if err := readJSON(filepath.Join(directory, "metadata.json"), &metadata); err != nil {
		return identityView{}, err
	}
	if err := validateManagedDirectoryID(directory, metadata.ID, "id"); err != nil {
		return identityView{}, err
	}
	privateKeyPath := filepath.Join(directory, "client.key")
	csrPath := filepath.Join(directory, "client.csr")
	keyPEM, err := readLimitedFile(privateKeyPath)
	if err != nil {
		return identityView{}, err
	}
	defer clear(keyPEM)
	key, err := parsePrivateKeyPEM(keyPEM)
	if err != nil {
		return identityView{}, err
	}
	csrPEM, err := readLimitedFile(csrPath)
	if err != nil {
		return identityView{}, err
	}
	csr, err := parseCSRPEM(csrPEM)
	if err != nil || !publicKeysEqual(csr.PublicKey, key.Public()) {
		return identityView{}, problem("CSR_KEY_MISMATCH", "managed CSR does not match its private key")
	}
	if _, _, err := validateCSRPolicy(csr, "client"); err != nil {
		return identityView{}, err
	}
	name, nameErr := validateDisplayText(metadata.Name, "identity name", true)
	commonName, commonNameErr := validateDisplayText(metadata.CommonName, "identity common name", true)
	metadataDNS, metadataIPs, namesErr := validateNames(metadata.DNSNames, metadata.IPAddresses)
	if nameErr != nil || commonNameErr != nil || namesErr != nil ||
		name != metadata.Name || commonName != metadata.CommonName ||
		metadata.CommonName != csr.Subject.CommonName ||
		metadata.Algorithm != publicKeyAlgorithm(csr.PublicKey) ||
		!equalStrings(metadataDNS, csr.DNSNames) ||
		!equalIPAddresses(metadataIPs, csr.IPAddresses) {
		return identityView{}, problem("INVALID_METADATA", "managed identity metadata does not match its CSR")
	}
	if _, err := time.Parse(time.RFC3339, metadata.CreatedAt); err != nil {
		return identityView{}, problem("INVALID_METADATA", "managed identity creation time is invalid")
	}
	metadata.DNSNames = metadataDNS
	metadata.IPAddresses = canonicalIPStrings(metadataIPs)
	view := identityView{
		identityMetadata: metadata,
		PrivateKeyPath:   privateKeyPath,
		CSRPath:          csrPath,
		Status:           "csr_ready",
	}
	certificatePath := filepath.Join(directory, "client.crt")
	certificatePEM, certificateErr := readLimitedFile(certificatePath)
	if certificateErr == nil {
		// Retain the path whenever an artifact exists, even when its contents
		// fail closed below. Callers can then distinguish a damaged installed
		// certificate from an identity that is still waiting for one.
		view.CertificatePath = certificatePath
		certificates, parseErr := parseCertificatesPEM(certificatePEM)
		if parseErr != nil ||
			validateLeafCertificate(certificates[0], key, "client") != nil ||
			!csrMatchesCertificate(csr, certificates[0]) {
			view.Status = "invalid"
			return view, nil
		}
		leaf := certificates[0]
		view.Issuer = leaf.Issuer.String()
		view.NotAfter = leaf.NotAfter.UTC().Format(time.RFC3339)
		view.Fingerprint = certificateFingerprint(leaf)
		view.Status = "certificate_installed"
		trustedPath := filepath.Join(directory, "trusted-server-ca.crt")
		trustedPEM, trustedErr := readLimitedFile(trustedPath)
		if trustedErr == nil {
			view.TrustedCAPath = trustedPath
			trustedCertificates, validationErr := inspectCABundle(trustedPEM)
			if validationErr != nil {
				view.TrustedCAStatus = "invalid"
				view.Status = "trusted_ca_invalid"
				return view, nil
			}
			view.TrustedCAs = trustedCAViews(trustedCertificates)
			view.TrustedCAStatus = aggregateCAStatus(view.TrustedCAs)
			switch view.TrustedCAStatus {
			case "valid", "expiring":
				view.Status = "ready"
			case "not_yet_valid":
				view.Status = "trusted_ca_not_yet_valid"
			case "expired":
				view.Status = "trusted_ca_expired"
			default:
				view.Status = "trusted_ca_invalid"
			}
		} else if !isNotFoundProblem(trustedErr) {
			return identityView{}, trustedErr
		}
	} else if !isNotFoundProblem(certificateErr) {
		// An unsafe, unreadable, empty, or oversized certificate artifact still
		// means an installation was attempted. Keep the managed path visible and
		// fail the identity closed instead of presenting it as CSR-only.
		view.CertificatePath = certificatePath
		view.Status = "invalid"
	}
	return view, nil
}

func trustedCAViews(certificates []*x509.Certificate) []trustedCACertificateView {
	views := make([]trustedCACertificateView, 0, len(certificates))
	for _, certificate := range certificates {
		views = append(views, trustedCACertificateView{
			Subject:     certificate.Subject.String(),
			NotBefore:   certificate.NotBefore.UTC().Format(time.RFC3339),
			NotAfter:    certificate.NotAfter.UTC().Format(time.RFC3339),
			Fingerprint: certificateFingerprint(certificate),
			Status:      validityStatus(certificate.NotBefore, certificate.NotAfter),
		})
	}
	return views
}

func aggregateCAStatus(certificates []trustedCACertificateView) string {
	status := "valid"
	for _, certificate := range certificates {
		switch certificate.Status {
		case "expired":
			return "expired"
		case "not_yet_valid":
			status = "not_yet_valid"
		case "expiring":
			if status == "valid" {
				status = "expiring"
			}
		case "valid":
		default:
			return "invalid"
		}
	}
	return status
}

func issuedViewFromDir(root, directory string) (issuedView, error) {
	var metadata issuedMetadata
	if err := readJSON(filepath.Join(directory, "metadata.json"), &metadata); err != nil {
		return issuedView{}, err
	}
	if err := validateManagedDirectoryID(directory, metadata.ID, "cert"); err != nil {
		return issuedView{}, err
	}
	expectedDirectory, err := managedDir(root, "issued", metadata.ID, "cert")
	if err != nil || filepath.Clean(directory) != filepath.Clean(expectedDirectory) {
		return issuedView{}, problem("INVALID_METADATA", "issued certificate ID does not match its directory")
	}
	if err := validateManagedID(metadata.CAID, "ca"); err != nil {
		return issuedView{}, problem("INVALID_METADATA", "issued certificate CA ID is invalid")
	}
	if metadata.Role != strings.ToLower(strings.TrimSpace(metadata.Role)) ||
		(metadata.Role != "client" && metadata.Role != "server") {
		return issuedView{}, problem("INVALID_METADATA", "issued certificate role is invalid")
	}
	if name, err := validateDisplayText(metadata.Name, "certificate name", true); err != nil || name != metadata.Name {
		return issuedView{}, problem("INVALID_METADATA", "issued certificate metadata contains an invalid name")
	}
	if _, err := time.Parse(time.RFC3339, metadata.IssuedAt); err != nil {
		return issuedView{}, problem("INVALID_METADATA", "issued certificate creation time is invalid")
	}
	certificatePath := filepath.Join(directory, "certificate.crt")
	certificatePEM, err := readLimitedFile(certificatePath)
	if err != nil {
		return issuedView{}, err
	}
	certificates, err := parseCertificatesPEM(certificatePEM)
	if err != nil || len(certificates) != 1 {
		return issuedView{}, problem("INVALID_CERTIFICATE", "issued certificate file must contain exactly one certificate")
	}
	certificate := certificates[0]
	if metadata.Fingerprint != certificateFingerprint(certificate) {
		return issuedView{}, problem("INVALID_CERTIFICATE", "issued certificate fingerprint changed")
	}
	if metadata.Subject != certificate.Subject.String() ||
		metadata.SerialNumber != certificate.SerialNumber.Text(16) ||
		metadata.NotAfter != certificate.NotAfter.UTC().Format(time.RFC3339) {
		return issuedView{}, problem("INVALID_METADATA", "issued certificate metadata does not match its certificate")
	}
	caCertificatePath := filepath.Join(directory, "ca.crt")
	caPEM, err := readLimitedFile(caCertificatePath)
	if err != nil {
		return issuedView{}, err
	}
	caCertificates, err := parseCertificatesPEM(caPEM)
	if err != nil || len(caCertificates) != 1 {
		return issuedView{}, problem("INVALID_CA", "stored issuing CA file must contain exactly one certificate")
	}
	if err := validateIssuedCertificate(certificate, caCertificates[0], metadata.Role); err != nil {
		return issuedView{}, err
	}
	view := issuedView{
		issuedMetadata:    metadata,
		CertificatePath:   certificatePath,
		CACertificatePath: caCertificatePath,
		Status:            validityStatus(certificate.NotBefore, certificate.NotAfter),
	}
	if metadata.HasPrivateKey {
		view.PrivateKeyPath = filepath.Join(directory, "private.key")
		privateKeyPEM, err := readLimitedFile(view.PrivateKeyPath)
		if err != nil {
			return issuedView{}, err
		}
		defer clear(privateKeyPEM)
		privateKey, err := parsePrivateKeyPEM(privateKeyPEM)
		if err != nil {
			return issuedView{}, err
		}
		if !publicKeysEqual(certificate.PublicKey, privateKey.Public()) {
			return issuedView{}, problem("CERT_KEY_MISMATCH", "issued certificate does not match its stored private key")
		}
	} else {
		unexpectedKeyPath := filepath.Join(directory, "private.key")
		unexpectedKey, err := readLimitedFile(unexpectedKeyPath)
		if err == nil {
			clear(unexpectedKey)
			return issuedView{}, problem("INVALID_METADATA", "issued certificate private-key metadata is inconsistent")
		} else if !isNotFoundProblem(err) {
			return issuedView{}, err
		}
	}
	csrPath := filepath.Join(directory, "request.csr")
	csrPEM, err := readLimitedFile(csrPath)
	if err != nil {
		return issuedView{}, err
	}
	csr, err := parseCSRPEM(csrPEM)
	if err != nil {
		return issuedView{}, err
	}
	if !csrMatchesCertificate(csr, certificate) {
		return issuedView{}, problem("CSR_CERT_MISMATCH", "stored CSR does not match its issued certificate")
	}
	view.CSRPath = csrPath
	return view, nil
}

func normalizeValidity(value, fallback, minimum, maximum int) (int, error) {
	if value == 0 {
		value = fallback
	}
	if value < minimum || value > maximum {
		return 0, problem(
			"INVALID_VALIDITY",
			fmt.Sprintf("validity must be between %d and %d days", minimum, maximum),
		)
	}
	return value, nil
}

func validityStatus(notBefore, notAfter time.Time) string {
	now := time.Now().UTC()
	if now.Before(notBefore) {
		return "not_yet_valid"
	}
	if !now.Before(notAfter) {
		return "expired"
	}
	if notAfter.Sub(now) <= 30*24*time.Hour {
		return "expiring"
	}
	return "valid"
}

func publicKeyAlgorithm(key any) string {
	switch typed := key.(type) {
	case *rsa.PublicKey:
		return fmt.Sprintf("rsa-%d", typed.N.BitLen())
	case *ecdsa.PublicKey:
		switch typed.Curve {
		case elliptic.P256():
			return "ecdsa-p256"
		case elliptic.P384():
			return "ecdsa-p384"
		case elliptic.P521():
			return "ecdsa-p521"
		default:
			return "ecdsa-unknown"
		}
	case ed25519.PublicKey:
		return "ed25519"
	default:
		return "unknown"
	}
}

func canonicalIPStrings(addresses []net.IP) []string {
	values := make([]string, 0, len(addresses))
	for _, address := range addresses {
		values = append(values, address.String())
	}
	return values
}

func equalIPAddresses(left, right []net.IP) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if !left[index].Equal(right[index]) {
			return false
		}
	}
	return true
}

func isNotFoundProblem(err error) bool {
	var typed *apiError
	return errors.As(err, &typed) && typed.Code == "NOT_FOUND"
}
