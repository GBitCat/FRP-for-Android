package main

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testCAPassword = "correct horse battery staple"

func TestManagedPKIWorkflow(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Home Client CA",
		CommonName: "home-client-ca",
		Algorithm:  "ecdsa-p256",
		Password:   testCAPassword,
		ValidDays:  3650,
	})

	encryptedKey, err := os.ReadFile(authority.EncryptedKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encryptedKey), "PRIVATE KEY") {
		t.Fatal("CA private key was stored as plaintext PEM")
	}
	if mode := mustMode(t, authority.EncryptedKeyPath); mode.Perm() != 0o600 {
		t.Fatalf("encrypted CA key mode = %o, want 600", mode.Perm())
	}

	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Living Room Phone",
		CommonName: "living-room-phone",
		DNSNames:   []string{"living-room-phone"},
		Algorithm:  "ecdsa-p256",
	})
	if identity.Status != "csr_ready" {
		t.Fatalf("identity status = %q, want csr_ready", identity.Status)
	}
	if mode := mustMode(t, identity.PrivateKeyPath); mode.Perm() != 0o600 {
		t.Fatalf("client key mode = %o, want 600", mode.Perm())
	}

	wrongPassword := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "sign_identity",
		Root:       root,
		IdentityID: identity.ID,
		CAID:       authority.ID,
		Password:   "wrong password with enough length",
	})
	if wrongPassword.OK || wrongPassword.Code != "INVALID_CA_PASSWORD" {
		t.Fatalf("wrong password response = %#v", wrongPassword)
	}

	identity = mustData[identityView](t, apiRequest{
		APIVersion:           1,
		Operation:            "sign_identity",
		Root:                 root,
		IdentityID:           identity.ID,
		CAID:                 authority.ID,
		Password:             testCAPassword,
		ValidDays:            365,
		UseCAAsTrustedServer: true,
	})
	if identity.Status != "ready" {
		t.Fatalf("identity status = %q, want ready", identity.Status)
	}
	verifyCertificate(t, authority.CertificatePath, identity.CertificatePath, x509.ExtKeyUsageClientAuth, "")

	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Authorities) != 1 || len(inventory.Identities) != 1 || len(inventory.Issued) != 1 {
		t.Fatalf("unexpected inventory sizes: %#v", inventory)
	}

	inUse := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "delete_ca",
		Root:       root,
		ID:         authority.ID,
	})
	if inUse.OK || inUse.Code != "CA_IN_USE" {
		t.Fatalf("in-use CA deletion response = %#v", inUse)
	}
}

func TestInventoryBindsMetadataToCertificateArtifacts(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Metadata CA",
		CommonName: "metadata-ca",
		Password:   testCAPassword,
	})
	identity := mustData[identityView](t, apiRequest{
		APIVersion:  1,
		Operation:   "create_identity",
		Root:        root,
		Name:        "Metadata Client",
		CommonName:  "metadata-client",
		DNSNames:    []string{"CLIENT.EXAMPLE", "client.example"},
		IPAddresses: []string{"2001:0db8:0:0:0:0:0:1", "2001:db8::1"},
	})
	if len(identity.DNSNames) != 1 || identity.DNSNames[0] != "client.example" ||
		len(identity.IPAddresses) != 1 || identity.IPAddresses[0] != "2001:db8::1" {
		t.Fatalf("identity SAN metadata was not canonicalized: %#v", identity)
	}
	issued := mustData[issuedView](t, apiRequest{
		APIVersion: 1,
		Operation:  "generate_server_certificate",
		Root:       root,
		CAID:       authority.ID,
		Password:   testCAPassword,
		Name:       "Metadata Server",
		CommonName: "server.example",
		DNSNames:   []string{"server.example"},
		Algorithm:  "ecdsa-p256",
		ValidDays:  365,
	})

	var authorityMetadataValue authorityMetadata
	authorityMetadataPath := filepath.Join(filepath.Dir(authority.CertificatePath), "metadata.json")
	if err := readJSON(authorityMetadataPath, &authorityMetadataValue); err != nil {
		t.Fatal(err)
	}
	authorityMetadataValue.Algorithm = "rsa-2048"
	if err := writeJSON(authorityMetadataPath, authorityMetadataValue); err != nil {
		t.Fatal(err)
	}
	rejectedSign := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "sign_identity",
		Root:       root,
		IdentityID: identity.ID,
		CAID:       authority.ID,
		Password:   testCAPassword,
	})
	if rejectedSign.OK || rejectedSign.Code != "INVALID_METADATA" {
		t.Fatalf("signing with mismatched CA metadata = %#v", rejectedSign)
	}

	var identityMetadataValue identityMetadata
	identityMetadataPath := filepath.Join(filepath.Dir(identity.CSRPath), "metadata.json")
	if err := readJSON(identityMetadataPath, &identityMetadataValue); err != nil {
		t.Fatal(err)
	}
	identityMetadataValue.CommonName = "different-client"
	if err := writeJSON(identityMetadataPath, identityMetadataValue); err != nil {
		t.Fatal(err)
	}

	var issuedMetadataValue issuedMetadata
	issuedMetadataPath := filepath.Join(filepath.Dir(issued.CertificatePath), "metadata.json")
	if err := readJSON(issuedMetadataPath, &issuedMetadataValue); err != nil {
		t.Fatal(err)
	}
	issuedMetadataValue.IssuedAt = "not-a-timestamp"
	if err := writeJSON(issuedMetadataPath, issuedMetadataValue); err != nil {
		t.Fatal(err)
	}

	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Authorities) != 0 || len(inventory.Identities) != 0 ||
		len(inventory.Issued) != 0 || len(inventory.Warnings) != 3 {
		t.Fatalf("metadata-bound inventory = %#v", inventory)
	}
}

func TestInventoryWarningsAreBounded(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tls")
	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	category := filepath.Join(root, "authorities")
	for index := 0; index < maxInventoryWarnings+5; index++ {
		if err := os.Mkdir(
			filepath.Join(category, fmt.Sprintf("damaged-%03d", index)),
			0o700,
		); err != nil {
			t.Fatal(err)
		}
	}

	inventory, err := listInventory(apiRequest{Root: root})
	if err != nil {
		t.Fatal(err)
	}
	if len(inventory.Warnings) != maxInventoryWarnings {
		t.Fatalf("warning count = %d, want %d", len(inventory.Warnings), maxInventoryWarnings)
	}
	if got := inventory.Warnings[len(inventory.Warnings)-1]; got != "additional damaged certificate records were omitted" {
		t.Fatalf("last inventory warning = %q", got)
	}
}

func TestSignExternalServerCSR(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Server CA",
		CommonName: "server-ca",
		Password:   testCAPassword,
	})
	_, csrPEM, _, _, err := createCSR(
		"frps.example.com",
		"",
		"ecdsa-p256",
		[]string{"frps.example.com"},
		[]net.IP{net.ParseIP("192.0.2.10")},
	)
	if err != nil {
		t.Fatal(err)
	}
	inspection := mustData[csrInspectionView](t, apiRequest{
		APIVersion: 1,
		Operation:  "inspect_csr",
		Root:       root,
		CSRPem:     string(csrPEM),
	})
	if inspection.CommonName != "frps.example.com" ||
		inspection.PublicKeyAlgorithm != "ECDSA P-256" ||
		inspection.PublicKeyBits != 256 || !inspection.CanSignAsServer ||
		inspection.Fingerprint == "" {
		t.Fatalf("unexpected CSR inspection: %#v", inspection)
	}
	issued := mustData[issuedView](t, apiRequest{
		APIVersion: 1,
		Operation:  "sign_csr",
		Root:       root,
		CAID:       authority.ID,
		Password:   testCAPassword,
		Name:       "Primary FRPS",
		Role:       "server",
		ValidDays:  365,
		CSRPem:     string(csrPEM),
	})
	if issued.Role != "server" || issued.HasPrivateKey {
		t.Fatalf("unexpected issued server record: %#v", issued)
	}
	verifyCertificate(t, authority.CertificatePath, issued.CertificatePath, x509.ExtKeyUsageServerAuth, "frps.example.com")
}

func TestSignExternalCSRRequiresExplicitRole(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Role CA",
		CommonName: "role-ca",
		Password:   testCAPassword,
	})
	_, csrPEM, _, _, err := createCSR(
		"client.example.com",
		"",
		"ecdsa-p256",
		[]string{"client.example.com"},
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}

	response := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "sign_csr",
		Root:       root,
		CAID:       authority.ID,
		Password:   testCAPassword,
		CSRPem:     string(csrPEM),
	})
	if response.OK || response.Code != "INVALID_ROLE" {
		t.Fatalf("missing-role response = %#v", response)
	}
	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Issued) != 0 {
		t.Fatalf("missing-role request created issued records: %#v", inventory.Issued)
	}
}

func TestRejectWeakExternalCSRPublicKeyAtInspectionAndSigning(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Policy CA",
		CommonName: "policy-ca",
		Password:   testCAPassword,
	})
	weakKey, err := rsa.GenerateKey(rand.Reader, 1024)
	if err != nil {
		t.Fatal(err)
	}
	requestDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject:  pkix.Name{CommonName: "weak-client"},
		DNSNames: []string{"weak-client"},
	}, weakKey)
	if err != nil {
		t.Fatal(err)
	}
	csrPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: requestDER})
	for _, operation := range []string{"inspect_csr", "sign_csr"} {
		response := dispatch(apiRequest{
			APIVersion: 1,
			Operation:  operation,
			Root:       root,
			CAID:       authority.ID,
			Password:   testCAPassword,
			Role:       "client",
			CSRPem:     string(csrPEM),
		})
		if response.OK || response.Code != "WEAK_PUBLIC_KEY" {
			t.Fatalf("%s response = %#v", operation, response)
		}
	}
	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Issued) != 0 {
		t.Fatalf("weak CSR created issued records: %#v", inventory.Issued)
	}
}

func TestRejectWeakOrUnknownExternalCSRSignatures(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "CSR Signature CA",
		CommonName: "csr-signature-ca",
		Password:   testCAPassword,
	})
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	sha1DER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject:            pkix.Name{CommonName: "signature-client"},
		DNSNames:           []string{"signature-client.example"},
		SignatureAlgorithm: x509.SHA1WithRSA,
	}, key)
	if err != nil {
		t.Fatal(err)
	}
	sha1OID := []byte{0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x05}
	if count := bytes.Count(sha1DER, sha1OID); count != 1 {
		t.Fatalf("CSR SHA-1 signature OID count = %d, want 1", count)
	}
	for _, testCase := range []struct {
		name    string
		oidLast byte
	}{
		{name: "MD2", oidLast: 0x02},
		{name: "MD5", oidLast: 0x04},
		{name: "SHA-1", oidLast: 0x05},
		{name: "unknown", oidLast: 0x63},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			der := append([]byte(nil), sha1DER...)
			if testCase.oidLast != 0x05 {
				replacement := append([]byte(nil), sha1OID...)
				replacement[len(replacement)-1] = testCase.oidLast
				der = bytes.ReplaceAll(der, sha1OID, replacement)
			}
			csrPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der})
			for _, operation := range []string{"inspect_csr", "sign_csr"} {
				response := dispatch(apiRequest{
					APIVersion: 1,
					Operation:  operation,
					Root:       root,
					CAID:       authority.ID,
					Password:   testCAPassword,
					Role:       "client",
					CSRPem:     string(csrPEM),
				})
				if response.OK || response.Code != "WEAK_CSR_SIGNATURE" {
					t.Fatalf("%s response = %#v", operation, response)
				}
			}
		})
	}
	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Issued) != 0 {
		t.Fatalf("rejected CSR created issued records: %#v", inventory.Issued)
	}
}

func TestSecureSignatureAlgorithmAllowlist(t *testing.T) {
	for _, algorithm := range []x509.SignatureAlgorithm{
		x509.SHA256WithRSA,
		x509.SHA384WithRSA,
		x509.SHA512WithRSA,
		x509.ECDSAWithSHA256,
		x509.ECDSAWithSHA384,
		x509.ECDSAWithSHA512,
		x509.SHA256WithRSAPSS,
		x509.SHA384WithRSAPSS,
		x509.SHA512WithRSAPSS,
		x509.PureEd25519,
	} {
		if !secureSignatureAlgorithm(algorithm) {
			t.Fatalf("secure signature algorithm %v was rejected", algorithm)
		}
	}
	for _, algorithm := range []x509.SignatureAlgorithm{
		x509.UnknownSignatureAlgorithm,
		x509.MD2WithRSA,
		x509.MD5WithRSA,
		x509.SHA1WithRSA,
		x509.ECDSAWithSHA1,
	} {
		if secureSignatureAlgorithm(algorithm) {
			t.Fatalf("obsolete or unknown signature algorithm %v was accepted", algorithm)
		}
	}
}

func TestRejectCSRSubjectAndSANTypesThatCannotBePreserved(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	unsupportedSAN, err := asn1.Marshal([]asn1.RawValue{
		{Class: asn1.ClassContextSpecific, Tag: 2, Bytes: []byte("client.example")},
		{Class: asn1.ClassContextSpecific, Tag: 8, Bytes: []byte{0x2a, 0x03}},
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, testCase := range []struct {
		name     string
		template *x509.CertificateRequest
		code     string
	}{
		{
			name: "unsupported subject attribute",
			template: &x509.CertificateRequest{Subject: pkix.Name{
				CommonName: "client",
				ExtraNames: []pkix.AttributeTypeAndValue{{
					Type:  asn1.ObjectIdentifier{1, 2, 3, 4},
					Value: "opaque identity",
				}},
			}},
			code: "INVALID_SUBJECT",
		},
		{
			name: "unsupported SAN general name",
			template: &x509.CertificateRequest{
				Subject: pkix.Name{CommonName: "client"},
				ExtraExtensions: []pkix.Extension{{
					Id:    oidSubjectAltName,
					Value: unsupportedSAN,
				}},
			},
			code: "INVALID_SAN",
		},
		{
			name: "empty subject with non-critical SAN",
			template: &x509.CertificateRequest{
				DNSNames: []string{"client.example"},
			},
			code: "INVALID_SAN",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			requestDER, err := x509.CreateCertificateRequest(rand.Reader, testCase.template, key)
			if err != nil {
				t.Fatal(err)
			}
			request, err := x509.ParseCertificateRequest(requestDER)
			if err != nil {
				t.Fatal(err)
			}
			_, _, err = validateCSRPolicy(request, "client")
			var typed *apiError
			if !errors.As(err, &typed) || typed.Code != testCase.code {
				t.Fatalf("validation error = %v, want %s", err, testCase.code)
			}
		})
	}
}

func TestIssueCertificatePreservesCriticalSANExtension(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sanDER, err := asn1.Marshal([]asn1.RawValue{{
		Class: asn1.ClassContextSpecific,
		Tag:   2,
		Bytes: []byte("client.example"),
	}})
	if err != nil {
		t.Fatal(err)
	}
	requestDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject: pkix.Name{CommonName: "critical-san-client"},
		ExtraExtensions: []pkix.Extension{{
			Id:       oidSubjectAltName,
			Critical: true,
			Value:    sanDER,
		}},
	}, key)
	if err != nil {
		t.Fatal(err)
	}
	request, err := x509.ParseCertificateRequest(requestDER)
	if err != nil {
		t.Fatal(err)
	}
	caKeyPEM, _, ca, _, err := createCA("san-ca", "", "ecdsa-p256", 365)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(caKeyPEM)
	caKey, err := parsePrivateKeyPEM(caKeyPEM)
	if err != nil {
		t.Fatal(err)
	}
	_, certificate, err := issueCertificate(request, ca, caKey, "client", 30)
	if err != nil {
		t.Fatal(err)
	}
	requestSAN, requestHasSAN := subjectAlternativeNameExtension(request.Extensions)
	certificateSAN, certificateHasSAN := subjectAlternativeNameExtension(certificate.Extensions)
	if !requestHasSAN || !certificateHasSAN || !certificateSAN.Critical ||
		!bytes.Equal(requestSAN.Value, certificateSAN.Value) ||
		!csrMatchesCertificate(request, certificate) {
		t.Fatal("issued certificate did not preserve the critical SAN extension")
	}

	altered := *certificate
	altered.Extensions = append([]pkix.Extension(nil), certificate.Extensions...)
	for index := range altered.Extensions {
		if altered.Extensions[index].Id.Equal(oidSubjectAltName) {
			altered.Extensions[index].Critical = false
		}
	}
	if csrMatchesCertificate(request, &altered) {
		t.Fatal("certificate with changed SAN criticality matched its CSR")
	}
}

func TestIssueCertificatePreservesSupportedCSRSubjectDER(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	rawSubject, err := asn1.Marshal(pkix.RDNSequence{
		{
			{Type: asn1.ObjectIdentifier{2, 5, 4, 3}, Value: "client"},
			{Type: asn1.ObjectIdentifier{2, 5, 4, 10}, Value: "Example"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	requestDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		RawSubject: rawSubject,
	}, key)
	if err != nil {
		t.Fatal(err)
	}
	request, err := x509.ParseCertificateRequest(requestDER)
	if err != nil {
		t.Fatal(err)
	}
	caKeyPEM, _, ca, _, err := createCA("subject-ca", "", "ecdsa-p256", 365)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(caKeyPEM)
	caKey, err := parsePrivateKeyPEM(caKeyPEM)
	if err != nil {
		t.Fatal(err)
	}
	_, certificate, err := issueCertificate(request, ca, caKey, "client", 30)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(certificate.RawSubject, request.RawSubject) ||
		!csrMatchesCertificate(request, certificate) {
		t.Fatal("issued certificate did not preserve the CSR subject DER")
	}

	separateSubject, err := asn1.Marshal(pkix.RDNSequence{
		{{Type: asn1.ObjectIdentifier{2, 5, 4, 3}, Value: "client"}},
		{{Type: asn1.ObjectIdentifier{2, 5, 4, 10}, Value: "Example"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	altered := *certificate
	altered.RawSubject = separateSubject
	if csrMatchesCertificate(request, &altered) {
		t.Fatal("different RDN grouping was treated as the same CSR subject")
	}
}

func TestValidateDNSSubjectAlternativeNames(t *testing.T) {
	for _, name := range []string{
		"bad_name.example",
		"-bad.example",
		"bad-.example",
		"bad..example",
		"*bad.example",
		"example.com.",
		"192.0.2.10",
		"例子.example",
	} {
		if _, _, err := validateNames([]string{name}, nil); err == nil {
			t.Fatalf("invalid DNS SAN %q was accepted", name)
		}
	}
	valid, _, err := validateNames(
		[]string{"frps", "*.example.com", "xn--fsqu00a.example"},
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(valid) != 3 {
		t.Fatalf("valid DNS SANs = %#v", valid)
	}
}

func TestGenerateServerCertificateWithPrivateKey(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Local CA",
		CommonName: "local-ca",
		Password:   testCAPassword,
	})
	issued := mustData[issuedView](t, apiRequest{
		APIVersion:  1,
		Operation:   "generate_server_certificate",
		Root:        root,
		CAID:        authority.ID,
		Password:    testCAPassword,
		Name:        "Local FRPS",
		CommonName:  "frps.local",
		DNSNames:    []string{"frps.local"},
		IPAddresses: []string{"192.0.2.20"},
		Algorithm:   "rsa-2048",
		ValidDays:   365,
	})
	if !issued.HasPrivateKey || issued.PrivateKeyPath == "" {
		t.Fatalf("generated server record has no private key: %#v", issued)
	}
	if mode := mustMode(t, issued.PrivateKeyPath); mode.Perm() != 0o600 {
		t.Fatalf("server key mode = %o, want 600", mode.Perm())
	}
	verifyCertificate(t, authority.CertificatePath, issued.CertificatePath, x509.ExtKeyUsageServerAuth, "frps.local")
}

func TestIssuedInventoryRejectsMismatchedArtifacts(t *testing.T) {
	for _, testCase := range []struct {
		name        string
		corrupt     func(*testing.T, issuedView)
		wantWarning string
	}{
		{
			name: "private key",
			corrupt: func(t *testing.T, issued issuedView) {
				t.Helper()
				privateKey, _, _, _, err := createCSR("other-server", "", "ecdsa-p256", []string{"other-server"}, nil)
				if err != nil {
					t.Fatal(err)
				}
				if err := atomicWrite(issued.PrivateKeyPath, privateKey, 0o600); err != nil {
					t.Fatal(err)
				}
			},
			wantWarning: "does not match its stored private key",
		},
		{
			name: "issuing CA",
			corrupt: func(t *testing.T, issued issuedView) {
				t.Helper()
				now := time.Now().UTC()
				otherCA := testCAPEM(t, now.Add(-time.Hour), now.Add(24*time.Hour))
				if err := atomicWrite(issued.CACertificatePath, otherCA, 0o644); err != nil {
					t.Fatal(err)
				}
			},
			wantWarning: "stored CA",
		},
		{
			name: "CSR",
			corrupt: func(t *testing.T, issued issuedView) {
				t.Helper()
				_, otherCSR, _, _, err := createCSR("other-server", "", "ecdsa-p256", []string{"other-server"}, nil)
				if err != nil {
					t.Fatal(err)
				}
				if err := atomicWrite(issued.CSRPath, otherCSR, 0o644); err != nil {
					t.Fatal(err)
				}
			},
			wantWarning: "stored CSR does not match",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			root := t.TempDir()
			authority := mustData[authorityView](t, apiRequest{
				APIVersion: 1,
				Operation:  "create_ca",
				Root:       root,
				Name:       "Integrity CA",
				CommonName: "integrity-ca",
				Password:   testCAPassword,
			})
			issued := mustData[issuedView](t, apiRequest{
				APIVersion: 1,
				Operation:  "generate_server_certificate",
				Root:       root,
				CAID:       authority.ID,
				Password:   testCAPassword,
				Name:       "Integrity Server",
				CommonName: "integrity.example.com",
				DNSNames:   []string{"integrity.example.com"},
			})
			testCase.corrupt(t, issued)

			inventory := mustData[inventoryView](t, apiRequest{
				APIVersion: 1,
				Operation:  "list_inventory",
				Root:       root,
			})
			if len(inventory.Issued) != 0 || len(inventory.Warnings) != 1 ||
				!strings.Contains(inventory.Warnings[0], testCase.wantWarning) {
				t.Fatalf("corrupt issued inventory = %#v", inventory)
			}
		})
	}
}

func TestImportAuthorityRecovery(t *testing.T) {
	sourceRoot := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       sourceRoot,
		Name:       "Recoverable CA",
		CommonName: "recoverable-ca",
		Password:   testCAPassword,
	})
	certificatePEM, err := os.ReadFile(authority.CertificatePath)
	if err != nil {
		t.Fatal(err)
	}
	encryptedKey, err := os.ReadFile(authority.EncryptedKeyPath)
	if err != nil {
		t.Fatal(err)
	}

	destinationRoot := t.TempDir()
	wrongPassword := dispatch(apiRequest{
		APIVersion:          1,
		Operation:           "import_ca_recovery",
		Root:                destinationRoot,
		Password:            "wrong password with enough length",
		CertificatePem:      string(certificatePEM),
		EncryptedKeyPayload: string(encryptedKey),
	})
	if wrongPassword.OK || wrongPassword.Code != "INVALID_CA_PASSWORD" {
		t.Fatalf("wrong recovery password response = %#v", wrongPassword)
	}

	recovered := mustData[authorityView](t, apiRequest{
		APIVersion:          1,
		Operation:           "import_ca_recovery",
		Root:                destinationRoot,
		Name:                "Recovered CA",
		Password:            testCAPassword,
		CertificatePem:      string(certificatePEM),
		EncryptedKeyPayload: string(encryptedKey),
	})
	if recovered.Name != "Recovered CA" || recovered.Fingerprint != authority.Fingerprint ||
		recovered.Algorithm != authority.Algorithm {
		t.Fatalf("unexpected recovered authority: %#v", recovered)
	}
	if mode := mustMode(t, recovered.EncryptedKeyPath); mode.Perm() != 0o600 {
		t.Fatalf("recovered encrypted CA key mode = %o, want 600", mode.Perm())
	}

	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       destinationRoot,
		Name:       "Recovered Client",
		CommonName: "recovered-client",
	})
	identity = mustData[identityView](t, apiRequest{
		APIVersion:           1,
		Operation:            "sign_identity",
		Root:                 destinationRoot,
		IdentityID:           identity.ID,
		CAID:                 recovered.ID,
		Password:             testCAPassword,
		UseCAAsTrustedServer: true,
	})
	verifyCertificate(
		t,
		recovered.CertificatePath,
		identity.CertificatePath,
		x509.ExtKeyUsageClientAuth,
		"",
	)
}

func TestImportAuthorityRecoveryRejectsNotYetValidCA(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	certificatePEM := testCAPEMForSigner(
		t,
		key,
		now.Add(24*time.Hour),
		now.Add(48*time.Hour),
	)
	certificates, err := parseCertificatesPEM(certificatePEM)
	if err != nil {
		t.Fatal(err)
	}
	privateKeyPEM, err := marshalPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(privateKeyPEM)
	encryptedKey, err := encryptCAKey(
		privateKeyPEM,
		testCAPassword,
		certificateFingerprint(certificates[0]),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(encryptedKey)

	root := t.TempDir()
	response := dispatch(apiRequest{
		APIVersion:          1,
		Operation:           "import_ca_recovery",
		Root:                root,
		Password:            testCAPassword,
		CertificatePem:      string(certificatePEM),
		EncryptedKeyPayload: string(encryptedKey),
	})
	if response.OK || response.Code != "CA_NOT_YET_VALID" {
		t.Fatalf("not-yet-valid recovery response = %#v", response)
	}
	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Authorities) != 0 {
		t.Fatalf("not-yet-valid CA was imported: %#v", inventory.Authorities)
	}
}

func TestInventoryRejectsMetadataIDsThatDoNotMatchDirectories(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Metadata CA",
		CommonName: "metadata-ca",
		Password:   testCAPassword,
	})
	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Metadata Identity",
		CommonName: "metadata-identity",
	})

	var authorityMetadataValue authorityMetadata
	authorityMetadataPath := filepath.Join(filepath.Dir(authority.CertificatePath), "metadata.json")
	if err := readJSON(authorityMetadataPath, &authorityMetadataValue); err != nil {
		t.Fatal(err)
	}
	authorityMetadataValue.ID = "ca-aaaaaaaaaaaaaaaaaaaaaaaa"
	if err := writeJSON(authorityMetadataPath, authorityMetadataValue); err != nil {
		t.Fatal(err)
	}

	var identityMetadataValue identityMetadata
	identityMetadataPath := filepath.Join(filepath.Dir(identity.CSRPath), "metadata.json")
	if err := readJSON(identityMetadataPath, &identityMetadataValue); err != nil {
		t.Fatal(err)
	}
	identityMetadataValue.ID = "id-bbbbbbbbbbbbbbbbbbbbbbbb"
	if err := writeJSON(identityMetadataPath, identityMetadataValue); err != nil {
		t.Fatal(err)
	}

	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Authorities) != 0 || len(inventory.Identities) != 0 ||
		len(inventory.Warnings) != 2 {
		t.Fatalf("metadata mismatch inventory = %#v", inventory)
	}
}

func TestRejectOversizedCAPasswordsBeforeKeyDerivation(t *testing.T) {
	root := t.TempDir()
	tooLong := strings.Repeat("x", maxCAPasswordBytes+1)
	create := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Bounded CA",
		CommonName: "bounded-ca",
		Password:   tooLong,
	})
	if create.OK || create.Code != "WEAK_PASSWORD" {
		t.Fatalf("oversized create password response = %#v", create)
	}

	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Valid CA",
		CommonName: "valid-ca",
		Password:   testCAPassword,
	})
	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Client",
		CommonName: "client",
	})
	unlock := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "sign_identity",
		Root:       root,
		IdentityID: identity.ID,
		CAID:       authority.ID,
		Password:   tooLong,
	})
	if unlock.OK || unlock.Code != "INVALID_CA_PASSWORD" {
		t.Fatalf("oversized unlock password response = %#v", unlock)
	}
}

func TestRejectMismatchedIdentityCertificateAndUnsafeID(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Client CA",
		CommonName: "client-ca",
		Password:   testCAPassword,
	})
	first := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "First",
		CommonName: "first",
	})
	first = mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "sign_identity",
		Root:       root,
		IdentityID: first.ID,
		CAID:       authority.ID,
		Password:   testCAPassword,
	})
	second := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Second",
		CommonName: "second",
	})
	firstCertificate, err := os.ReadFile(first.CertificatePath)
	if err != nil {
		t.Fatal(err)
	}
	mismatch := dispatch(apiRequest{
		APIVersion:     1,
		Operation:      "install_identity",
		Root:           root,
		IdentityID:     second.ID,
		CertificatePem: string(firstCertificate),
	})
	if mismatch.OK || mismatch.Code != "CERT_KEY_MISMATCH" {
		t.Fatalf("mismatch response = %#v", mismatch)
	}

	unsafe := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "delete_identity",
		Root:       root,
		ID:         "../../escape",
	})
	if unsafe.OK || unsafe.Code != "INVALID_ID" {
		t.Fatalf("unsafe path response = %#v", unsafe)
	}
}

func TestTrustedCABundleValidityIsEnforcedAndReported(t *testing.T) {
	root := t.TempDir()
	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Validity Client",
		CommonName: "validity-client",
	})
	now := time.Now().UTC()
	expired := testCAPEM(t, now.Add(-48*time.Hour), now.Add(-24*time.Hour))
	notYetValid := testCAPEM(t, now.Add(24*time.Hour), now.Add(48*time.Hour))
	for name, certificate := range map[string][]byte{
		"expired":       expired,
		"not yet valid": notYetValid,
	} {
		response := dispatch(apiRequest{
			APIVersion:   1,
			Operation:    "install_trusted_ca",
			Root:         root,
			IdentityID:   identity.ID,
			TrustedCAPem: string(certificate),
		})
		if response.OK {
			t.Fatalf("%s CA was accepted", name)
		}
	}

	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Current CA",
		CommonName: "current-ca",
		Password:   testCAPassword,
	})
	identity = mustData[identityView](t, apiRequest{
		APIVersion:           1,
		Operation:            "sign_identity",
		Root:                 root,
		IdentityID:           identity.ID,
		CAID:                 authority.ID,
		Password:             testCAPassword,
		UseCAAsTrustedServer: true,
	})
	if identity.Status != "ready" {
		t.Fatalf("initial identity status = %q", identity.Status)
	}
	if err := atomicWrite(identity.TrustedCAPath, expired, 0o644); err != nil {
		t.Fatal(err)
	}
	identity = mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	}).Identities[0]
	if identity.Status != "trusted_ca_expired" || identity.TrustedCAStatus != "expired" ||
		len(identity.TrustedCAs) != 1 || identity.TrustedCAs[0].Fingerprint == "" {
		t.Fatalf("expired trusted CA identity = %#v", identity)
	}
}

func TestValidateCABundleOperationRejectsInvalidDER(t *testing.T) {
	root := t.TempDir()
	now := time.Now().UTC()
	valid := testCAPEM(t, now.Add(-time.Hour), now.Add(24*time.Hour))
	result := mustData[map[string]any](t, apiRequest{
		APIVersion:   1,
		Operation:    "validate_ca_bundle",
		Root:         root,
		TrustedCAPem: string(valid),
	})
	if result["count"] != 1 {
		t.Fatalf("validated CA count = %#v", result["count"])
	}

	invalid := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "validate_ca_bundle",
		Root:       root,
		TrustedCAPem: "-----BEGIN CERTIFICATE-----\n" +
			"AQID\n-----END CERTIFICATE-----\n",
	})
	if invalid.OK || invalid.Code != "INVALID_CERTIFICATE" {
		t.Fatalf("invalid DER response = %#v", invalid)
	}
}

func TestTrustedCABundleEnforcesPublicKeyStrength(t *testing.T) {
	now := time.Now().UTC()
	weakRSA, err := rsa.GenerateKey(rand.Reader, 1024)
	if err != nil {
		t.Fatal(err)
	}
	weak := dispatch(apiRequest{
		APIVersion:   1,
		Operation:    "validate_ca_bundle",
		Root:         t.TempDir(),
		TrustedCAPem: string(testCAPEMForSigner(t, weakRSA, now.Add(-time.Hour), now.Add(24*time.Hour))),
	})
	if weak.OK || weak.Code != "WEAK_CA_PUBLIC_KEY" {
		t.Fatalf("weak CA response = %#v", weak)
	}

	strongRSA, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	weakSignature := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "validate_ca_bundle",
		Root:       t.TempDir(),
		TrustedCAPem: string(testCAPEMForSignerWithSignature(
			t,
			strongRSA,
			now.Add(-time.Hour),
			now.Add(24*time.Hour),
			x509.SHA1WithRSA,
		)),
	})
	if weakSignature.OK || weakSignature.Code != "WEAK_CA_SIGNATURE" {
		t.Fatalf("SHA-1 CA response = %#v", weakSignature)
	}
	_, strongEd25519, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	strongP384, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	for name, signer := range map[string]crypto.Signer{
		"rsa-2048":   strongRSA,
		"ecdsa-p384": strongP384,
		"ed25519":    strongEd25519,
	} {
		t.Run(name, func(t *testing.T) {
			result := dispatch(apiRequest{
				APIVersion:   1,
				Operation:    "validate_ca_bundle",
				Root:         t.TempDir(),
				TrustedCAPem: string(testCAPEMForSigner(t, signer, now.Add(-time.Hour), now.Add(24*time.Hour))),
			})
			if !result.OK {
				t.Fatalf("strong CA response = %#v", result)
			}
		})
	}
}

func TestInstallIdentityValidatesAllInputsBeforeReplacingFiles(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Transaction CA",
		CommonName: "transaction-ca",
		Password:   testCAPassword,
	})
	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Transaction Client",
		CommonName: "transaction-client",
	})
	identity = mustData[identityView](t, apiRequest{
		APIVersion:           1,
		Operation:            "sign_identity",
		Root:                 root,
		IdentityID:           identity.ID,
		CAID:                 authority.ID,
		Password:             testCAPassword,
		UseCAAsTrustedServer: true,
	})
	originalCertificate, err := os.ReadFile(identity.CertificatePath)
	if err != nil {
		t.Fatal(err)
	}
	originalTrustedCA, err := os.ReadFile(identity.TrustedCAPath)
	if err != nil {
		t.Fatal(err)
	}
	response := dispatch(apiRequest{
		APIVersion:     1,
		Operation:      "install_identity",
		Root:           root,
		IdentityID:     identity.ID,
		CertificatePem: string(originalCertificate) + "\n",
		TrustedCAPem:   "not a CA certificate",
	})
	if response.OK || response.Code == "" {
		t.Fatalf("invalid combined install response = %#v", response)
	}
	currentCertificate, err := os.ReadFile(identity.CertificatePath)
	if err != nil {
		t.Fatal(err)
	}
	currentTrustedCA, err := os.ReadFile(identity.TrustedCAPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(currentCertificate) != string(originalCertificate) ||
		string(currentTrustedCA) != string(originalTrustedCA) {
		t.Fatal("failed combined install modified existing identity files")
	}
}

func TestInstallIdentityRejectsCertificateWithAlteredCSRIdentity(t *testing.T) {
	for _, testCase := range []struct {
		name       string
		commonName string
		dnsNames   []string
	}{
		{
			name:       "subject",
			commonName: "different-client",
			dnsNames:   []string{"managed-client.example"},
		},
		{
			name:       "subject alternative name",
			commonName: "managed-client",
			dnsNames:   []string{"different-client.example"},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			root := t.TempDir()
			authority := mustData[authorityView](t, apiRequest{
				APIVersion: 1,
				Operation:  "create_ca",
				Root:       root,
				Name:       "Install CA",
				CommonName: "install-ca",
				Password:   testCAPassword,
			})
			identity := mustData[identityView](t, apiRequest{
				APIVersion: 1,
				Operation:  "create_identity",
				Root:       root,
				Name:       "Managed Client",
				CommonName: "managed-client",
				DNSNames:   []string{"managed-client.example"},
			})
			certificatePEM := issueClientCertificateForIdentityKey(
				t,
				root,
				authority.ID,
				identity,
				testCase.commonName,
				testCase.dnsNames,
			)

			response := dispatch(apiRequest{
				APIVersion:     1,
				Operation:      "install_identity",
				Root:           root,
				IdentityID:     identity.ID,
				CertificatePem: string(certificatePEM),
			})
			if response.OK || response.Code != "CSR_CERT_MISMATCH" {
				t.Fatalf("altered %s response = %#v", testCase.name, response)
			}
			if _, err := os.Stat(filepath.Join(filepath.Dir(identity.CSRPath), "client.crt")); !os.IsNotExist(err) {
				t.Fatalf("rejected certificate was installed: %v", err)
			}

			// Inventory must also fail closed if files were changed outside the API.
			if err := atomicWrite(
				filepath.Join(filepath.Dir(identity.CSRPath), "client.crt"),
				certificatePEM,
				0o644,
			); err != nil {
				t.Fatal(err)
			}
			inventory := mustData[inventoryView](t, apiRequest{
				APIVersion: 1,
				Operation:  "list_inventory",
				Root:       root,
			})
			if len(inventory.Identities) != 1 || inventory.Identities[0].Status != "invalid" {
				t.Fatalf("altered %s inventory = %#v", testCase.name, inventory)
			}
		})
	}
}

func TestInstallAndInventoryRejectWeakCertificateSignatures(t *testing.T) {
	root := t.TempDir()
	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Weak Signature Client",
		CommonName: "weak-signature-client",
		DNSNames:   []string{"weak-signature-client.example"},
	})
	csrPEM, err := os.ReadFile(identity.CSRPath)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := parseCSRPEM(csrPEM)
	if err != nil {
		t.Fatal(err)
	}
	sha1DER := testClientCertificateDER(
		t,
		csr,
		x509.SHA1WithRSA,
		x509.KeyUsageDigitalSignature,
	)
	sha1OID := []byte{0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x05}
	certificatePath := filepath.Join(filepath.Dir(identity.CSRPath), "client.crt")
	for _, testCase := range []struct {
		name      string
		oidLast   byte
		algorithm x509.SignatureAlgorithm
	}{
		{name: "MD2", oidLast: 0x02, algorithm: x509.UnknownSignatureAlgorithm},
		{name: "MD5", oidLast: 0x04, algorithm: x509.MD5WithRSA},
		{name: "SHA-1", oidLast: 0x05, algorithm: x509.SHA1WithRSA},
		{name: "unknown", oidLast: 0x63, algorithm: x509.UnknownSignatureAlgorithm},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			der := append([]byte(nil), sha1DER...)
			if testCase.oidLast != 0x05 {
				replacement := append([]byte(nil), sha1OID...)
				replacement[len(replacement)-1] = testCase.oidLast
				if count := bytes.Count(der, sha1OID); count != 2 {
					t.Fatalf("SHA-1 signature OID count = %d, want 2", count)
				}
				der = bytes.ReplaceAll(der, sha1OID, replacement)
			}
			parsed, err := x509.ParseCertificate(der)
			if err != nil {
				t.Fatal(err)
			}
			if parsed.SignatureAlgorithm != testCase.algorithm {
				t.Fatalf(
					"signature algorithm = %v, want %v",
					parsed.SignatureAlgorithm,
					testCase.algorithm,
				)
			}
			certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
			response := dispatch(apiRequest{
				APIVersion:     1,
				Operation:      "install_identity",
				Root:           root,
				IdentityID:     identity.ID,
				CertificatePem: string(certificatePEM),
			})
			if response.OK || response.Code != "WEAK_CERT_SIGNATURE" {
				t.Fatalf("weak certificate response = %#v", response)
			}
			if _, err := os.Stat(certificatePath); !os.IsNotExist(err) {
				t.Fatalf("rejected certificate was installed: %v", err)
			}

			// Inventory must also fail closed if a weakly signed certificate is
			// introduced outside the managed installation API.
			if err := atomicWrite(certificatePath, certificatePEM, 0o644); err != nil {
				t.Fatal(err)
			}
			inventory := mustData[inventoryView](t, apiRequest{
				APIVersion: 1,
				Operation:  "list_inventory",
				Root:       root,
			})
			if len(inventory.Identities) != 1 || inventory.Identities[0].Status != "invalid" {
				t.Fatalf("weak certificate inventory = %#v", inventory)
			}
			if err := os.Remove(certificatePath); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestInstallAndInventoryRejectCertificateWithoutDigitalSignatureUsage(t *testing.T) {
	root := t.TempDir()
	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Key Usage Client",
		CommonName: "key-usage-client",
		DNSNames:   []string{"key-usage-client.example"},
	})
	csrPEM, err := os.ReadFile(identity.CSRPath)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := parseCSRPEM(csrPEM)
	if err != nil {
		t.Fatal(err)
	}
	certificatePEM := pem.EncodeToMemory(&pem.Block{
		Type: "CERTIFICATE",
		Bytes: testClientCertificateDER(
			t,
			csr,
			x509.SHA256WithRSA,
			x509.KeyUsageKeyEncipherment,
		),
	})
	response := dispatch(apiRequest{
		APIVersion:     1,
		Operation:      "install_identity",
		Root:           root,
		IdentityID:     identity.ID,
		CertificatePem: string(certificatePEM),
	})
	if response.OK || response.Code != "INVALID_KEY_USAGE" {
		t.Fatalf("missing digitalSignature response = %#v", response)
	}

	certificatePath := filepath.Join(filepath.Dir(identity.CSRPath), "client.crt")
	if err := atomicWrite(certificatePath, certificatePEM, 0o644); err != nil {
		t.Fatal(err)
	}
	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Identities) != 1 ||
		inventory.Identities[0].Status != "invalid" ||
		inventory.Identities[0].CertificatePath != certificatePath {
		t.Fatalf("invalid installed certificate was not reported clearly: %#v", inventory)
	}
}

func testClientCertificateDER(
	t *testing.T,
	csr *x509.CertificateRequest,
	signatureAlgorithm x509.SignatureAlgorithm,
	keyUsage x509.KeyUsage,
) []byte {
	t.Helper()
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "signature-policy-ca"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(
		rand.Reader,
		caTemplate,
		caTemplate,
		caKey.Public(),
		caKey,
	)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               csr.Subject,
		RawSubject:            append([]byte(nil), csr.RawSubject...),
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              keyUsage,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		DNSNames:              append([]string(nil), csr.DNSNames...),
		IPAddresses:           append([]net.IP(nil), csr.IPAddresses...),
		EmailAddresses:        append([]string(nil), csr.EmailAddresses...),
		URIs:                  csr.URIs,
		SignatureAlgorithm:    signatureAlgorithm,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, csr.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

func issueClientCertificateForIdentityKey(
	t *testing.T,
	root, caID string,
	identity identityView,
	commonName string,
	dnsNames []string,
) []byte {
	t.Helper()
	keyPEM, err := os.ReadFile(identity.PrivateKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	key, err := parsePrivateKeyPEM(keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	requestDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject:  pkix.Name{CommonName: commonName},
		DNSNames: dnsNames,
	}, key)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := x509.ParseCertificateRequest(requestDER)
	if err != nil {
		t.Fatal(err)
	}
	_, authority, authorityKey, err := loadAuthority(root, caID, testCAPassword)
	if err != nil {
		t.Fatal(err)
	}
	certificatePEM, _, err := issueCertificate(csr, authority, authorityKey, "client", 365)
	if err != nil {
		t.Fatal(err)
	}
	return certificatePEM
}

func TestSignIdentityPreparationFailureDoesNotCreateIssuedRecord(t *testing.T) {
	root := t.TempDir()
	authority := mustData[authorityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_ca",
		Root:       root,
		Name:       "Transaction CA",
		CommonName: "transaction-ca",
		Password:   testCAPassword,
	})
	identity := mustData[identityView](t, apiRequest{
		APIVersion: 1,
		Operation:  "create_identity",
		Root:       root,
		Name:       "Blocked Client",
		CommonName: "blocked-client",
	})
	blockedPath := filepath.Join(filepath.Dir(identity.PrivateKeyPath), "client.crt")
	if err := os.Mkdir(blockedPath, 0o700); err != nil {
		t.Fatal(err)
	}
	response := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "sign_identity",
		Root:       root,
		IdentityID: identity.ID,
		CAID:       authority.ID,
		Password:   testCAPassword,
	})
	if response.OK {
		t.Fatal("signing unexpectedly succeeded with an unsafe identity entry")
	}
	if err := os.Remove(blockedPath); err != nil {
		t.Fatal(err)
	}
	inventory := mustData[inventoryView](t, apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if len(inventory.Issued) != 0 || inventory.Identities[0].Status != "csr_ready" {
		t.Fatalf("failed sign left partial state: %#v", inventory)
	}
}

func testCAPEM(t *testing.T, notBefore, notAfter time.Time) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return testCAPEMForSigner(t, key, notBefore, notAfter)
}

func testCAPEMForSigner(
	t *testing.T,
	key crypto.Signer,
	notBefore, notAfter time.Time,
) []byte {
	t.Helper()
	return testCAPEMForSignerWithSignature(
		t,
		key,
		notBefore,
		notAfter,
		x509.UnknownSignatureAlgorithm,
	)
}

func testCAPEMForSignerWithSignature(
	t *testing.T,
	key crypto.Signer,
	notBefore, notAfter time.Time,
	signatureAlgorithm x509.SignatureAlgorithm,
) []byte {
	t.Helper()
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test-ca"},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		SignatureAlgorithm:    signatureAlgorithm,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func TestRejectSymlinkedStorageCategory(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "authorities")); err != nil {
		t.Fatal(err)
	}
	response := dispatch(apiRequest{
		APIVersion: 1,
		Operation:  "list_inventory",
		Root:       root,
	})
	if response.OK || response.Code != "PATH_REJECTED" {
		t.Fatalf("symlinked category response = %#v", response)
	}
}

func mustData[T any](t *testing.T, request apiRequest) T {
	t.Helper()
	response := dispatch(request)
	if !response.OK {
		t.Fatalf("operation %q failed: %s: %s", request.Operation, response.Code, response.Message)
	}
	data, ok := response.Data.(T)
	if !ok {
		t.Fatalf("operation %q returned %T", request.Operation, response.Data)
	}
	return data
}

func mustMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode()
}

func verifyCertificate(t *testing.T, caPath, certificatePath string, usage x509.ExtKeyUsage, hostname string) {
	t.Helper()
	caPEM, err := os.ReadFile(filepath.Clean(caPath))
	if err != nil {
		t.Fatal(err)
	}
	certificatePEM, err := os.ReadFile(filepath.Clean(certificatePath))
	if err != nil {
		t.Fatal(err)
	}
	caCertificates, err := parseCertificatesPEM(caPEM)
	if err != nil {
		t.Fatal(err)
	}
	certificates, err := parseCertificatesPEM(certificatePEM)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(caCertificates[0])
	if _, err := certificates[0].Verify(x509.VerifyOptions{
		Roots:     roots,
		KeyUsages: []x509.ExtKeyUsage{usage},
		DNSName:   hostname,
	}); err != nil {
		t.Fatalf("certificate verification failed: %v", err)
	}
}
