package main

import (
	"bytes"
	"crypto"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/mail"
	"net/url"
	"path/filepath"
	"strings"
	"time"
)

const (
	caKeyIterations       = 600_000
	minCAPasswordBytes    = 12
	maxCAPasswordBytes    = 4096
	maxCertificatesPerPEM = 64
	maxSubjectAttributes  = 64
)

var (
	oidSubjectAltName    = asn1.ObjectIdentifier{2, 5, 29, 17}
	supportedSubjectOIDs = []asn1.ObjectIdentifier{
		{2, 5, 4, 3},  // commonName
		{2, 5, 4, 5},  // serialNumber
		{2, 5, 4, 6},  // countryName
		{2, 5, 4, 7},  // localityName
		{2, 5, 4, 8},  // stateOrProvinceName
		{2, 5, 4, 9},  // streetAddress
		{2, 5, 4, 10}, // organizationName
		{2, 5, 4, 11}, // organizationalUnitName
		{2, 5, 4, 17}, // postalCode
	}
)

type encryptedKeyEnvelope struct {
	Version     int    `json:"version"`
	KDF         string `json:"kdf"`
	Iterations  int    `json:"iterations"`
	Salt        string `json:"salt"`
	Nonce       string `json:"nonce"`
	Ciphertext  string `json:"ciphertext"`
	Fingerprint string `json:"fingerprint"`
}

func generateSigner(algorithm string) (crypto.Signer, string, error) {
	switch strings.ToLower(strings.TrimSpace(algorithm)) {
	case "", "ecdsa-p256":
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, "", problem("KEY_GENERATION_FAILED", "unable to generate ECDSA key", err)
		}
		return key, "ecdsa-p256", nil
	case "rsa-2048":
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return nil, "", problem("KEY_GENERATION_FAILED", "unable to generate RSA key", err)
		}
		if err := key.Validate(); err != nil {
			return nil, "", problem("KEY_GENERATION_FAILED", "generated RSA key is invalid", err)
		}
		return key, "rsa-2048", nil
	default:
		return nil, "", problem("UNSUPPORTED_ALGORITHM", "supported algorithms are ecdsa-p256 and rsa-2048")
	}
}

func marshalPrivateKey(signer crypto.Signer) ([]byte, error) {
	der, err := x509.MarshalPKCS8PrivateKey(signer)
	if err != nil {
		return nil, problem("KEY_ENCODING_FAILED", "unable to encode private key", err)
	}
	defer clear(der)
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

func parsePrivateKeyPEM(data []byte) (crypto.Signer, error) {
	block, rest := pem.Decode(data)
	if block == nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, problem("INVALID_PRIVATE_KEY", "private key PEM is invalid")
	}
	defer clear(block.Bytes)
	var parsed any
	var err error
	switch block.Type {
	case "PRIVATE KEY":
		parsed, err = x509.ParsePKCS8PrivateKey(block.Bytes)
	case "EC PRIVATE KEY":
		parsed, err = x509.ParseECPrivateKey(block.Bytes)
	case "RSA PRIVATE KEY":
		parsed, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	default:
		return nil, problem("INVALID_PRIVATE_KEY", "unsupported private key PEM type")
	}
	if err != nil {
		return nil, problem("INVALID_PRIVATE_KEY", "unable to parse private key", err)
	}
	signer, ok := parsed.(crypto.Signer)
	if !ok {
		return nil, problem("INVALID_PRIVATE_KEY", "private key type cannot sign certificates")
	}
	return signer, nil
}

func parseCertificatesPEM(data []byte) ([]*x509.Certificate, error) {
	var certificates []*x509.Certificate
	rest := data
	for len(bytes.TrimSpace(rest)) > 0 {
		if len(certificates) >= maxCertificatesPerPEM {
			return nil, problem(
				"INVALID_CERTIFICATE",
				"certificate PEM contains too many certificates",
			)
		}
		block, remaining := pem.Decode(rest)
		if block == nil {
			return nil, problem("INVALID_PEM", "certificate PEM contains invalid data")
		}
		rest = remaining
		if block.Type != "CERTIFICATE" {
			return nil, problem("INVALID_PEM", "PEM contains a non-certificate block")
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, problem("INVALID_CERTIFICATE", "unable to parse certificate", err)
		}
		certificates = append(certificates, certificate)
	}
	if len(certificates) == 0 {
		return nil, problem("INVALID_CERTIFICATE", "at least one certificate is required")
	}
	return certificates, nil
}

func parseCSRPEM(data []byte) (*x509.CertificateRequest, error) {
	block, rest := pem.Decode(data)
	if block == nil || len(bytes.TrimSpace(rest)) != 0 || block.Type != "CERTIFICATE REQUEST" {
		return nil, problem("INVALID_CSR", "certificate request PEM is invalid")
	}
	request, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil {
		return nil, problem("INVALID_CSR", "unable to parse certificate request", err)
	}
	if !secureSignatureAlgorithm(request.SignatureAlgorithm) {
		return nil, problem(
			"WEAK_CSR_SIGNATURE",
			"certificate request uses an obsolete or unsupported signature algorithm",
		)
	}
	if err := request.CheckSignature(); err != nil {
		return nil, problem("INVALID_CSR", "certificate request signature is invalid", err)
	}
	return request, nil
}

func randomSerial() (*big.Int, error) {
	serialBytes := make([]byte, 20)
	if _, err := rand.Read(serialBytes); err != nil {
		return nil, problem("RANDOM_FAILED", "unable to generate certificate serial number", err)
	}
	serialBytes[0] &= 0x7f
	if bytes.Equal(serialBytes, make([]byte, len(serialBytes))) {
		serialBytes[len(serialBytes)-1] = 1
	}
	return new(big.Int).SetBytes(serialBytes), nil
}

func subjectKeyID(publicKey any) ([]byte, error) {
	encoded, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		return nil, problem("KEY_ENCODING_FAILED", "unable to encode public key", err)
	}
	digest := sha256.Sum256(encoded)
	return append([]byte(nil), digest[:20]...), nil
}

func certificateFingerprint(certificate *x509.Certificate) string {
	return sha256Fingerprint(certificate.Raw)
}

func sha256Fingerprint(data []byte) string {
	digest := sha256.Sum256(data)
	encoded := strings.ToUpper(hex.EncodeToString(digest[:]))
	parts := make([]string, 0, len(encoded)/2)
	for index := 0; index < len(encoded); index += 2 {
		parts = append(parts, encoded[index:index+2])
	}
	return strings.Join(parts, ":")
}

func validateCSRPolicy(csr *x509.CertificateRequest, role string) (string, int, error) {
	if !secureSignatureAlgorithm(csr.SignatureAlgorithm) {
		return "", 0, problem(
			"WEAK_CSR_SIGNATURE",
			"certificate request uses an obsolete or unsupported signature algorithm",
		)
	}
	if err := csr.CheckSignature(); err != nil {
		return "", 0, problem("INVALID_CSR", "certificate request signature is invalid", err)
	}

	algorithm, bits, err := validateCSRPublicKey(csr.PublicKey)
	if err != nil {
		return "", 0, err
	}
	if len(csr.Raw) > 256*1024 || len(csr.Subject.String()) > 4096 {
		return "", 0, problem("INVALID_CSR", "certificate request subject is too large")
	}
	if err := validateCSRSubject(csr); err != nil {
		return "", 0, err
	}
	if err := validateSupportedSANExtension(
		csr.Extensions,
		len(csr.EmailAddresses),
		len(csr.DNSNames),
		len(csr.URIs),
		len(csr.IPAddresses),
	); err != nil {
		return "", 0, err
	}
	subject, err := parseSubject(csr.RawSubject)
	if err != nil {
		return "", 0, problem("INVALID_SUBJECT", "certificate request subject is invalid", err)
	}
	if san, ok := subjectAlternativeNameExtension(csr.Extensions); ok && len(subject) == 0 && !san.Critical {
		return "", 0, problem(
			"INVALID_SAN",
			"a certificate request with an empty subject must mark its SAN extension critical",
		)
	}
	ipStrings := make([]string, 0, len(csr.IPAddresses))
	for _, address := range csr.IPAddresses {
		ipStrings = append(ipStrings, address.String())
	}
	if _, _, err := validateNames(csr.DNSNames, ipStrings); err != nil {
		return "", 0, err
	}
	if len(csr.EmailAddresses) > 32 || len(csr.URIs) > 32 {
		return "", 0, problem("INVALID_SAN", "too many certificate SAN entries")
	}
	for _, address := range csr.EmailAddresses {
		parsed, parseErr := mail.ParseAddress(address)
		if parseErr != nil || parsed.Address != address || len(address) > 254 || containsControl(address) {
			return "", 0, problem("INVALID_SAN", "email SAN entry is invalid")
		}
	}
	for _, uri := range csr.URIs {
		if err := validateCSRURI(uri); err != nil {
			return "", 0, err
		}
	}
	role = strings.ToLower(strings.TrimSpace(role))
	if role != "" && role != "client" && role != "server" {
		return "", 0, problem("INVALID_ROLE", "certificate role must be client or server")
	}
	if role == "server" && len(csr.DNSNames) == 0 && len(csr.IPAddresses) == 0 {
		return "", 0, problem("INVALID_SAN", "server certificate requires at least one DNS or IP SAN")
	}
	if csr.Subject.CommonName == "" && len(csr.DNSNames) == 0 && len(csr.IPAddresses) == 0 {
		return "", 0, problem("INVALID_SUBJECT", "certificate request has no usable identity")
	}
	return algorithm, bits, nil
}

func validateCSRSubject(csr *x509.CertificateRequest) error {
	sequence, err := parseSubject(csr.RawSubject)
	if err != nil {
		return problem("INVALID_SUBJECT", "certificate request subject is invalid", err)
	}
	attributeCount := 0
	for _, set := range sequence {
		if len(set) == 0 {
			return problem("INVALID_SUBJECT", "certificate request subject contains an empty RDN")
		}
		for _, attribute := range set {
			attributeCount++
			if attributeCount > maxSubjectAttributes || !supportedSubjectOID(attribute.Type) {
				return problem(
					"INVALID_SUBJECT",
					"certificate request subject contains an unsupported attribute",
				)
			}
			value, ok := attribute.Value.(string)
			if !ok || len(value) > 1024 || containsControl(value) {
				return problem("INVALID_SUBJECT", "certificate request subject contains an invalid value")
			}
		}
	}
	return nil
}

func supportedSubjectOID(candidate asn1.ObjectIdentifier) bool {
	for _, supported := range supportedSubjectOIDs {
		if candidate.Equal(supported) {
			return true
		}
	}
	return false
}

func parseSubject(raw []byte) (pkix.RDNSequence, error) {
	var sequence pkix.RDNSequence
	rest, err := asn1.Unmarshal(raw, &sequence)
	if err != nil || len(rest) != 0 {
		return nil, fmt.Errorf("invalid subject DER")
	}
	return sequence, nil
}

func subjectsSemanticallyEqual(left, right []byte) bool {
	leftSequence, leftErr := parseSubject(left)
	rightSequence, rightErr := parseSubject(right)
	if leftErr != nil || rightErr != nil {
		return false
	}
	leftCanonical, leftErr := asn1.Marshal(leftSequence)
	rightCanonical, rightErr := asn1.Marshal(rightSequence)
	return leftErr == nil && rightErr == nil && bytes.Equal(leftCanonical, rightCanonical)
}

func validateSupportedSANExtension(
	extensions []pkix.Extension,
	emailCount, dnsCount, uriCount, ipCount int,
) error {
	var san *pkix.Extension
	for index := range extensions {
		if !extensions[index].Id.Equal(oidSubjectAltName) {
			continue
		}
		if san != nil {
			return problem("INVALID_SAN", "certificate contains duplicate SAN extensions")
		}
		san = &extensions[index]
	}
	if san == nil {
		if emailCount+dnsCount+uriCount+ipCount != 0 {
			return problem("INVALID_SAN", "certificate SAN metadata is inconsistent")
		}
		return nil
	}

	var names []asn1.RawValue
	rest, err := asn1.Unmarshal(san.Value, &names)
	if err != nil || len(rest) != 0 || len(names) == 0 {
		return problem("INVALID_SAN", "certificate SAN extension is invalid")
	}
	counts := map[int]int{}
	for _, name := range names {
		if name.Class != asn1.ClassContextSpecific || name.IsCompound {
			return problem("INVALID_SAN", "certificate SAN extension contains an unsupported name type")
		}
		switch name.Tag {
		case 1, 2, 6:
			for _, character := range name.Bytes {
				if character >= 0x80 {
					return problem("INVALID_SAN", "certificate SAN extension contains invalid IA5 text")
				}
			}
		case 7:
			if len(name.Bytes) != net.IPv4len && len(name.Bytes) != net.IPv6len {
				return problem("INVALID_SAN", "certificate SAN extension contains an invalid IP address")
			}
		default:
			return problem("INVALID_SAN", "certificate SAN extension contains an unsupported name type")
		}
		counts[name.Tag]++
	}
	if counts[1] != emailCount || counts[2] != dnsCount ||
		counts[6] != uriCount || counts[7] != ipCount {
		return problem("INVALID_SAN", "certificate SAN metadata is inconsistent")
	}
	return nil
}

func subjectAlternativeNameExtension(extensions []pkix.Extension) (pkix.Extension, bool) {
	for _, extension := range extensions {
		if extension.Id.Equal(oidSubjectAltName) {
			return extension, true
		}
	}
	return pkix.Extension{}, false
}

func validateCSRPublicKey(publicKey any) (string, int, error) {
	switch key := publicKey.(type) {
	case *rsa.PublicKey:
		bits := key.N.BitLen()
		if bits < 2048 || bits > 8192 || key.E < 65537 || key.E%2 == 0 {
			return "", 0, problem("WEAK_PUBLIC_KEY", "RSA public key must be 2048–8192 bits with a secure exponent")
		}
		return "RSA", bits, nil
	case *ecdsa.PublicKey:
		if key.Curve == nil || key.X == nil || key.Y == nil || !key.Curve.IsOnCurve(key.X, key.Y) {
			return "", 0, problem("INVALID_PUBLIC_KEY", "ECDSA public key is invalid")
		}
		switch key.Curve {
		case elliptic.P256():
			return "ECDSA P-256", 256, nil
		case elliptic.P384():
			return "ECDSA P-384", 384, nil
		case elliptic.P521():
			return "ECDSA P-521", 521, nil
		default:
			return "", 0, problem("WEAK_PUBLIC_KEY", "ECDSA public key must use P-256, P-384, or P-521")
		}
	case ed25519.PublicKey:
		if len(key) != ed25519.PublicKeySize {
			return "", 0, problem("INVALID_PUBLIC_KEY", "Ed25519 public key is invalid")
		}
		return "Ed25519", 256, nil
	default:
		return "", 0, problem("UNSUPPORTED_PUBLIC_KEY", "CSR public key must be RSA, ECDSA, or Ed25519")
	}
}

func validateCSRURI(uri *url.URL) error {
	if uri == nil || uri.Scheme == "" || len(uri.String()) > 2048 || uri.User != nil ||
		containsControl(uri.String()) {
		return problem("INVALID_SAN", "URI SAN entry is invalid")
	}
	return nil
}

func publicKeysEqual(left, right any) bool {
	leftDER, leftErr := x509.MarshalPKIXPublicKey(left)
	rightDER, rightErr := x509.MarshalPKIXPublicKey(right)
	return leftErr == nil && rightErr == nil && bytes.Equal(leftDER, rightDER)
}

func encryptCAKey(privateKeyPEM []byte, password, fingerprint string) ([]byte, error) {
	if len(password) < minCAPasswordBytes || len(password) > maxCAPasswordBytes {
		return nil, problem("WEAK_PASSWORD", "CA password must contain 12–4096 UTF-8 bytes")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, problem("RANDOM_FAILED", "unable to generate CA encryption salt", err)
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, caKeyIterations, 32)
	if err != nil {
		return nil, problem("KEY_ENCRYPTION_FAILED", "unable to derive CA encryption key", err)
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, problem("KEY_ENCRYPTION_FAILED", "unable to initialize CA encryption", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, problem("KEY_ENCRYPTION_FAILED", "unable to initialize CA authentication", err)
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, problem("RANDOM_FAILED", "unable to generate CA encryption nonce", err)
	}
	aad := []byte("frpc-cert-ca-key-v1:" + fingerprint)
	ciphertext := aead.Seal(nil, nonce, privateKeyPEM, aad)
	envelope := encryptedKeyEnvelope{
		Version:     1,
		KDF:         "PBKDF2-HMAC-SHA256",
		Iterations:  caKeyIterations,
		Salt:        base64.StdEncoding.EncodeToString(salt),
		Nonce:       base64.StdEncoding.EncodeToString(nonce),
		Ciphertext:  base64.StdEncoding.EncodeToString(ciphertext),
		Fingerprint: fingerprint,
	}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		return nil, problem("KEY_ENCRYPTION_FAILED", "unable to encode encrypted CA key", err)
	}
	return append(encoded, '\n'), nil
}

func decryptCAKey(encrypted []byte, password, expectedFingerprint string) (crypto.Signer, error) {
	if len(password) < minCAPasswordBytes || len(password) > maxCAPasswordBytes {
		return nil, problem("INVALID_CA_PASSWORD", "CA password must contain 12–4096 UTF-8 bytes")
	}
	if err := validateEncryptedCAKey(encrypted, expectedFingerprint); err != nil {
		return nil, err
	}
	var envelope encryptedKeyEnvelope
	if err := json.Unmarshal(encrypted, &envelope); err != nil {
		return nil, problem("INVALID_CA_KEY", "encrypted CA key is damaged", err)
	}
	if envelope.Version != 1 || envelope.KDF != "PBKDF2-HMAC-SHA256" ||
		envelope.Iterations < 100_000 || envelope.Iterations > 1_000_000 ||
		envelope.Fingerprint != expectedFingerprint {
		return nil, problem("INVALID_CA_KEY", "encrypted CA key metadata is invalid")
	}
	salt, saltErr := base64.StdEncoding.DecodeString(envelope.Salt)
	nonce, nonceErr := base64.StdEncoding.DecodeString(envelope.Nonce)
	ciphertext, cipherErr := base64.StdEncoding.DecodeString(envelope.Ciphertext)
	if saltErr != nil || nonceErr != nil || cipherErr != nil || len(salt) < 16 {
		return nil, problem("INVALID_CA_KEY", "encrypted CA key payload is invalid")
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, envelope.Iterations, 32)
	if err != nil {
		return nil, problem("INVALID_CA_PASSWORD", "unable to derive CA decryption key", err)
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, problem("INVALID_CA_KEY", "unable to initialize CA decryption", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil || len(nonce) != aead.NonceSize() {
		return nil, problem("INVALID_CA_KEY", "encrypted CA key nonce is invalid")
	}
	plain, err := aead.Open(nil, nonce, ciphertext, []byte("frpc-cert-ca-key-v1:"+expectedFingerprint))
	if err != nil {
		return nil, problem("INVALID_CA_PASSWORD", "CA password is incorrect or the key is damaged")
	}
	defer clear(plain)
	return parsePrivateKeyPEM(plain)
}

func validateEncryptedCAKey(encrypted []byte, expectedFingerprint string) error {
	var envelope encryptedKeyEnvelope
	if err := json.Unmarshal(encrypted, &envelope); err != nil {
		return problem("INVALID_CA_KEY", "encrypted CA key is damaged", err)
	}
	if envelope.Version != 1 || envelope.KDF != "PBKDF2-HMAC-SHA256" ||
		envelope.Iterations < 100_000 || envelope.Iterations > 1_000_000 ||
		envelope.Fingerprint != expectedFingerprint {
		return problem("INVALID_CA_KEY", "encrypted CA key metadata is invalid")
	}
	salt, saltErr := base64.StdEncoding.DecodeString(envelope.Salt)
	nonce, nonceErr := base64.StdEncoding.DecodeString(envelope.Nonce)
	ciphertext, cipherErr := base64.StdEncoding.DecodeString(envelope.Ciphertext)
	if saltErr != nil || nonceErr != nil || cipherErr != nil ||
		len(salt) < 16 || len(salt) > 32 || len(nonce) != 12 || len(ciphertext) < 16 {
		return problem("INVALID_CA_KEY", "encrypted CA key payload is invalid")
	}
	return nil
}

func validateNames(dnsNames, rawIPs []string) ([]string, []net.IP, error) {
	if len(dnsNames) > 32 || len(rawIPs) > 32 {
		return nil, nil, problem("INVALID_SAN", "too many certificate SAN entries")
	}
	cleanDNS := make([]string, 0, len(dnsNames))
	seenDNS := map[string]bool{}
	for _, raw := range dnsNames {
		name := strings.ToLower(strings.TrimSpace(raw))
		if !validDNSName(name) {
			return nil, nil, problem("INVALID_SAN", "DNS SAN entry is invalid")
		}
		if !seenDNS[name] {
			seenDNS[name] = true
			cleanDNS = append(cleanDNS, name)
		}
	}
	cleanIPs := make([]net.IP, 0, len(rawIPs))
	seenIPs := map[string]bool{}
	for _, raw := range rawIPs {
		parsed := net.ParseIP(strings.TrimSpace(raw))
		if parsed == nil {
			return nil, nil, problem("INVALID_SAN", "IP SAN entry is invalid")
		}
		canonical := parsed.String()
		if !seenIPs[canonical] {
			seenIPs[canonical] = true
			cleanIPs = append(cleanIPs, parsed)
		}
	}
	return cleanDNS, cleanIPs, nil
}

func validDNSName(name string) bool {
	if name == "" || len(name) > 253 || net.ParseIP(name) != nil || strings.HasSuffix(name, ".") {
		return false
	}
	labels := strings.Split(name, ".")
	for index, label := range labels {
		if label == "*" {
			if index != 0 || len(labels) < 2 {
				return false
			}
			continue
		}
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, character := range label {
			if (character < 'a' || character > 'z') &&
				(character < '0' || character > '9') && character != '-' {
				return false
			}
		}
	}
	return true
}

func createCA(commonName, organization, algorithm string, validDays int) ([]byte, []byte, *x509.Certificate, string, error) {
	signer, normalizedAlgorithm, err := generateSigner(algorithm)
	if err != nil {
		return nil, nil, nil, "", err
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, nil, nil, "", err
	}
	subjectID, err := subjectKeyID(signer.Public())
	if err != nil {
		return nil, nil, nil, "", err
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: commonName, Organization: optionalOrganization(organization)},
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.AddDate(0, 0, validDays),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
		SubjectKeyId:          subjectID,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, signer.Public(), signer)
	if err != nil {
		return nil, nil, nil, "", problem("CERTIFICATE_GENERATION_FAILED", "unable to generate CA certificate", err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, nil, "", problem("CERTIFICATE_GENERATION_FAILED", "generated CA certificate is invalid", err)
	}
	privateKey, err := marshalPrivateKey(signer)
	if err != nil {
		return nil, nil, nil, "", err
	}
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return privateKey, certificatePEM, certificate, normalizedAlgorithm, nil
}

func createCSR(commonName, organization, algorithm string, dnsNames []string, ipAddresses []net.IP) ([]byte, []byte, *x509.CertificateRequest, string, error) {
	signer, normalizedAlgorithm, err := generateSigner(algorithm)
	if err != nil {
		return nil, nil, nil, "", err
	}
	template := &x509.CertificateRequest{
		Subject:     pkix.Name{CommonName: commonName, Organization: optionalOrganization(organization)},
		DNSNames:    dnsNames,
		IPAddresses: ipAddresses,
	}
	der, err := x509.CreateCertificateRequest(rand.Reader, template, signer)
	if err != nil {
		return nil, nil, nil, "", problem("CSR_GENERATION_FAILED", "unable to generate certificate request", err)
	}
	request, err := x509.ParseCertificateRequest(der)
	if err != nil || request.CheckSignature() != nil {
		return nil, nil, nil, "", problem("CSR_GENERATION_FAILED", "generated certificate request is invalid", err)
	}
	privateKey, err := marshalPrivateKey(signer)
	if err != nil {
		return nil, nil, nil, "", err
	}
	csrPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der})
	return privateKey, csrPEM, request, normalizedAlgorithm, nil
}

func issueCertificate(csr *x509.CertificateRequest, ca *x509.Certificate, caKey crypto.Signer, role string, validDays int) ([]byte, *x509.Certificate, error) {
	role = strings.ToLower(strings.TrimSpace(role))
	if role != "client" && role != "server" {
		return nil, nil, problem("INVALID_ROLE", "certificate role must be client or server")
	}
	if _, _, err := validateCSRPolicy(csr, role); err != nil {
		return nil, nil, err
	}
	if !ca.IsCA || !publicKeysEqual(ca.PublicKey, caKey.Public()) {
		return nil, nil, problem("INVALID_CA_KEY", "CA certificate and private key do not match")
	}
	now := time.Now().UTC()
	if now.Before(ca.NotBefore) || !now.Before(ca.NotAfter) {
		return nil, nil, problem("CA_EXPIRED", "CA certificate is not currently valid")
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, nil, err
	}
	subjectID, err := subjectKeyID(csr.PublicKey)
	if err != nil {
		return nil, nil, err
	}
	notAfter := now.AddDate(0, 0, validDays)
	if notAfter.After(ca.NotAfter) {
		notAfter = ca.NotAfter
	}
	if !notAfter.After(now.Add(time.Hour)) {
		return nil, nil, problem("CA_EXPIRED", "CA expires too soon to issue a certificate")
	}
	keyUsage := x509.KeyUsageDigitalSignature
	extended := []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	if role == "server" {
		extended = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		if _, ok := csr.PublicKey.(*rsa.PublicKey); ok {
			keyUsage |= x509.KeyUsageKeyEncipherment
		}
	}
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               csr.Subject,
		RawSubject:            append([]byte(nil), csr.RawSubject...),
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              notAfter,
		KeyUsage:              keyUsage,
		ExtKeyUsage:           extended,
		BasicConstraintsValid: true,
		IsCA:                  false,
		DNSNames:              append([]string(nil), csr.DNSNames...),
		IPAddresses:           append([]net.IP(nil), csr.IPAddresses...),
		EmailAddresses:        append([]string(nil), csr.EmailAddresses...),
		URIs:                  csr.URIs,
		SubjectKeyId:          subjectID,
	}
	// Preserve the request's validated SAN DER and critical bit exactly. In
	// particular, x509.CreateCertificate would otherwise infer criticality
	// from the subject and could silently change the request's semantics.
	if san, ok := subjectAlternativeNameExtension(csr.Extensions); ok {
		template.ExtraExtensions = []pkix.Extension{{
			Id:       append(asn1.ObjectIdentifier(nil), san.Id...),
			Critical: san.Critical,
			Value:    append([]byte(nil), san.Value...),
		}}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, csr.PublicKey, caKey)
	if err != nil {
		return nil, nil, problem("CERTIFICATE_GENERATION_FAILED", "unable to sign certificate request", err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, problem("CERTIFICATE_GENERATION_FAILED", "signed certificate is invalid", err)
	}
	if !csrMatchesCertificate(csr, certificate) {
		return nil, nil, problem(
			"CERTIFICATE_GENERATION_FAILED",
			"signed certificate did not preserve the certificate request identity",
		)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), certificate, nil
}

func validateLeafCertificate(certificate *x509.Certificate, key crypto.Signer, role string) error {
	if err := validateCertificateRole(certificate, role); err != nil {
		return err
	}
	if err := validateLeafCertificateSignature(certificate); err != nil {
		return err
	}
	now := time.Now().UTC()
	if now.Before(certificate.NotBefore) {
		return problem("CERT_NOT_YET_VALID", "certificate is not valid yet")
	}
	if !now.Before(certificate.NotAfter) {
		return problem("CERT_EXPIRED", "certificate has expired")
	}
	if !publicKeysEqual(certificate.PublicKey, key.Public()) {
		return problem("CERT_KEY_MISMATCH", "certificate does not match the generated private key")
	}
	return nil
}

func validateCertificateRole(certificate *x509.Certificate, role string) error {
	role = strings.ToLower(strings.TrimSpace(role))
	if role != "client" && role != "server" {
		return problem("INVALID_ROLE", "certificate role must be client or server")
	}
	if certificate.IsCA {
		return problem("INVALID_CERTIFICATE", "a CA certificate cannot be installed as a device certificate")
	}
	if certificate.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		return problem(
			"INVALID_KEY_USAGE",
			fmt.Sprintf("certificate is missing digitalSignature usage required for TLS %s authentication", role),
		)
	}
	expected := x509.ExtKeyUsageClientAuth
	if role == "server" {
		expected = x509.ExtKeyUsageServerAuth
	}
	if len(certificate.ExtKeyUsage) > 0 {
		valid := false
		for _, usage := range certificate.ExtKeyUsage {
			if usage == expected || usage == x509.ExtKeyUsageAny {
				valid = true
				break
			}
		}
		if !valid {
			return problem("INVALID_KEY_USAGE", fmt.Sprintf("certificate is not valid for TLS %s authentication", role))
		}
	}
	return nil
}

func validateIssuedCertificate(certificate, authority *x509.Certificate, role string) error {
	if err := validateCertificateRole(certificate, role); err != nil {
		return err
	}
	if err := validateLeafCertificateSignature(certificate); err != nil {
		return err
	}
	if err := validateCACertificatePolicy(authority); err != nil {
		return err
	}
	if !bytes.Equal(certificate.RawIssuer, authority.RawSubject) {
		return problem("CA_CERT_MISMATCH", "issued certificate issuer does not match its stored CA")
	}
	if err := certificate.CheckSignatureFrom(authority); err != nil {
		return problem("CA_CERT_MISMATCH", "issued certificate was not signed by its stored CA", err)
	}
	return nil
}

func csrMatchesCertificate(csr *x509.CertificateRequest, certificate *x509.Certificate) bool {
	if !publicKeysEqual(csr.PublicKey, certificate.PublicKey) ||
		!subjectsSemanticallyEqual(csr.RawSubject, certificate.RawSubject) ||
		!equalStrings(csr.DNSNames, certificate.DNSNames) ||
		!equalStrings(csr.EmailAddresses, certificate.EmailAddresses) ||
		len(csr.IPAddresses) != len(certificate.IPAddresses) ||
		len(csr.URIs) != len(certificate.URIs) {
		return false
	}
	if validateSupportedSANExtension(
		csr.Extensions,
		len(csr.EmailAddresses),
		len(csr.DNSNames),
		len(csr.URIs),
		len(csr.IPAddresses),
	) != nil || validateSupportedSANExtension(
		certificate.Extensions,
		len(certificate.EmailAddresses),
		len(certificate.DNSNames),
		len(certificate.URIs),
		len(certificate.IPAddresses),
	) != nil {
		return false
	}
	csrSAN, csrHasSAN := subjectAlternativeNameExtension(csr.Extensions)
	certificateSAN, certificateHasSAN := subjectAlternativeNameExtension(certificate.Extensions)
	if csrHasSAN != certificateHasSAN ||
		(csrHasSAN && (csrSAN.Critical != certificateSAN.Critical ||
			!bytes.Equal(csrSAN.Value, certificateSAN.Value))) {
		return false
	}
	for index, address := range csr.IPAddresses {
		if !address.Equal(certificate.IPAddresses[index]) {
			return false
		}
	}
	for index, uri := range csr.URIs {
		if uri.String() != certificate.URIs[index].String() {
			return false
		}
	}
	return true
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func validateCABundle(data []byte) ([]*x509.Certificate, error) {
	certificates, err := inspectCABundle(data)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	for _, certificate := range certificates {
		if now.Before(certificate.NotBefore) {
			return nil, problem("CA_NOT_YET_VALID", "trusted CA bundle contains a certificate that is not valid yet")
		}
		if !now.Before(certificate.NotAfter) {
			return nil, problem("CA_EXPIRED", "trusted CA bundle contains an expired certificate")
		}
	}
	return certificates, nil
}

func inspectCABundle(data []byte) ([]*x509.Certificate, error) {
	certificates, err := parseCertificatesPEM(data)
	if err != nil {
		return nil, err
	}
	for _, certificate := range certificates {
		if err := validateCACertificatePolicy(certificate); err != nil {
			return nil, err
		}
	}
	return certificates, nil
}

func validateCACertificatePolicy(certificate *x509.Certificate) error {
	if certificate == nil || !certificate.IsCA || !certificate.BasicConstraintsValid ||
		certificate.KeyUsage&x509.KeyUsageCertSign == 0 {
		return problem("INVALID_CA", "CA certificate cannot sign certificates")
	}
	if !secureSignatureAlgorithm(certificate.SignatureAlgorithm) {
		return problem(
			"WEAK_CA_SIGNATURE",
			"CA certificate uses an obsolete or unsupported signature algorithm",
		)
	}
	if _, _, err := validateCSRPublicKey(certificate.PublicKey); err != nil {
		return problem(
			"WEAK_CA_PUBLIC_KEY",
			"CA certificate public key is unsupported or too weak",
			err,
		)
	}
	return nil
}

func validateLeafCertificateSignature(certificate *x509.Certificate) error {
	if certificate == nil || !secureSignatureAlgorithm(certificate.SignatureAlgorithm) {
		return problem(
			"WEAK_CERT_SIGNATURE",
			"certificate uses an obsolete or unsupported signature algorithm",
		)
	}
	return nil
}

// Keep this as an explicit allowlist so unknown signature OIDs fail closed.
func secureSignatureAlgorithm(algorithm x509.SignatureAlgorithm) bool {
	switch algorithm {
	case x509.SHA256WithRSA,
		x509.SHA384WithRSA,
		x509.SHA512WithRSA,
		x509.ECDSAWithSHA256,
		x509.ECDSAWithSHA384,
		x509.ECDSAWithSHA512,
		x509.SHA256WithRSAPSS,
		x509.SHA384WithRSAPSS,
		x509.SHA512WithRSAPSS,
		x509.PureEd25519:
		return true
	default:
		return false
	}
}

func optionalOrganization(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return []string{strings.TrimSpace(value)}
}

func loadAuthority(root, id, password string) (authorityMetadata, *x509.Certificate, crypto.Signer, error) {
	directory, err := managedDir(root, "authorities", id, "ca")
	if err != nil {
		return authorityMetadata{}, nil, nil, err
	}
	var metadata authorityMetadata
	if err := readJSON(filepath.Join(directory, "metadata.json"), &metadata); err != nil {
		return authorityMetadata{}, nil, nil, err
	}
	certificatePEM, err := readLimitedFile(filepath.Join(directory, "ca.crt"))
	if err != nil {
		return authorityMetadata{}, nil, nil, err
	}
	certificates, err := parseCertificatesPEM(certificatePEM)
	if err != nil || len(certificates) != 1 {
		return authorityMetadata{}, nil, nil, problem("INVALID_CA", "managed CA certificate is invalid")
	}
	certificate := certificates[0]
	if err := validateCACertificatePolicy(certificate); err != nil {
		return authorityMetadata{}, nil, nil, err
	}
	fingerprint := certificateFingerprint(certificate)
	if metadata.Fingerprint != fingerprint {
		return authorityMetadata{}, nil, nil, problem("INVALID_CA", "managed CA certificate fingerprint changed")
	}
	if metadata.CommonName != certificate.Subject.CommonName ||
		metadata.Algorithm != publicKeyAlgorithm(certificate.PublicKey) ||
		metadata.NotAfter != certificate.NotAfter.UTC().Format(time.RFC3339) {
		return authorityMetadata{}, nil, nil, problem("INVALID_METADATA", "managed CA metadata does not match its certificate")
	}
	if name, validationErr := validateDisplayText(metadata.Name, "CA name", true); validationErr != nil || name != metadata.Name {
		return authorityMetadata{}, nil, nil, problem("INVALID_METADATA", "managed CA metadata contains an invalid name")
	}
	if commonName, validationErr := validateDisplayText(metadata.CommonName, "CA common name", false); validationErr != nil || commonName != metadata.CommonName {
		return authorityMetadata{}, nil, nil, problem("INVALID_METADATA", "managed CA metadata contains an invalid common name")
	}
	if _, parseErr := time.Parse(time.RFC3339, metadata.CreatedAt); parseErr != nil {
		return authorityMetadata{}, nil, nil, problem("INVALID_METADATA", "managed CA creation time is invalid")
	}
	encryptedKey, err := readLimitedFile(filepath.Join(directory, "ca.key.enc"))
	if err != nil {
		return authorityMetadata{}, nil, nil, err
	}
	defer clear(encryptedKey)
	key, err := decryptCAKey(encryptedKey, password, fingerprint)
	if err != nil {
		return authorityMetadata{}, nil, nil, err
	}
	if !publicKeysEqual(certificate.PublicKey, key.Public()) {
		return authorityMetadata{}, nil, nil, problem("INVALID_CA_KEY", "managed CA key does not match its certificate")
	}
	return metadata, certificate, key, nil
}
