package main

import "fmt"

// A single operation can legitimately carry two managed files, for example a
// client certificate and its trusted server CA bundle. JSON escaping and the
// remaining request metadata need a small, explicit allowance on top.
const maxRequestBytes = (2 * maxManagedFileBytes) + (256 * 1024)

type apiRequest struct {
	APIVersion           int      `json:"apiVersion"`
	Operation            string   `json:"operation"`
	Root                 string   `json:"root"`
	ID                   string   `json:"id,omitempty"`
	CAID                 string   `json:"caId,omitempty"`
	IdentityID           string   `json:"identityId,omitempty"`
	Name                 string   `json:"name,omitempty"`
	CommonName           string   `json:"commonName,omitempty"`
	Organization         string   `json:"organization,omitempty"`
	Algorithm            string   `json:"algorithm,omitempty"`
	Password             string   `json:"password,omitempty"`
	ValidDays            int      `json:"validDays,omitempty"`
	DNSNames             []string `json:"dnsNames,omitempty"`
	IPAddresses          []string `json:"ipAddresses,omitempty"`
	Role                 string   `json:"role,omitempty"`
	CSRPem               string   `json:"csrPem,omitempty"`
	CertificatePem       string   `json:"certificatePem,omitempty"`
	TrustedCAPem         string   `json:"trustedCaPem,omitempty"`
	EncryptedKeyPayload  string   `json:"encryptedKeyPayload,omitempty"`
	UseCAAsTrustedServer bool     `json:"useCaAsTrustedServer,omitempty"`
	Force                bool     `json:"force,omitempty"`
}

type apiResponse struct {
	OK      bool   `json:"ok"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
	Data    any    `json:"data,omitempty"`
}

type apiError struct {
	Code    string
	Message string
	Cause   error
}

func (e *apiError) Error() string {
	if e.Cause == nil {
		return e.Message
	}
	return fmt.Sprintf("%s: %v", e.Message, e.Cause)
}

func problem(code, message string, cause ...error) error {
	var wrapped error
	if len(cause) > 0 {
		wrapped = cause[0]
	}
	return &apiError{Code: code, Message: message, Cause: wrapped}
}

func success(data any) apiResponse {
	return apiResponse{OK: true, Data: data}
}

func failure(code, message string) apiResponse {
	return apiResponse{OK: false, Code: code, Message: message}
}

func responseFromError(err error) apiResponse {
	if typed, ok := err.(*apiError); ok {
		return failure(typed.Code, typed.Message)
	}
	return failure("INTERNAL_ERROR", "certificate operation failed")
}

type authorityMetadata struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	CommonName  string `json:"commonName"`
	Algorithm   string `json:"algorithm"`
	CreatedAt   string `json:"createdAt"`
	NotAfter    string `json:"notAfter"`
	Fingerprint string `json:"fingerprint"`
}

type authorityView struct {
	authorityMetadata
	CertificatePath  string `json:"certificatePath"`
	EncryptedKeyPath string `json:"encryptedKeyPath"`
	Status           string `json:"status"`
}

type identityMetadata struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	CommonName  string   `json:"commonName"`
	Algorithm   string   `json:"algorithm"`
	DNSNames    []string `json:"dnsNames,omitempty"`
	IPAddresses []string `json:"ipAddresses,omitempty"`
	CreatedAt   string   `json:"createdAt"`
}

type identityView struct {
	identityMetadata
	PrivateKeyPath  string                     `json:"privateKeyPath"`
	CSRPath         string                     `json:"csrPath"`
	CertificatePath string                     `json:"certificatePath,omitempty"`
	TrustedCAPath   string                     `json:"trustedCaPath,omitempty"`
	TrustedCAStatus string                     `json:"trustedCaStatus,omitempty"`
	TrustedCAs      []trustedCACertificateView `json:"trustedCAs,omitempty"`
	Issuer          string                     `json:"issuer,omitempty"`
	NotAfter        string                     `json:"notAfter,omitempty"`
	Fingerprint     string                     `json:"fingerprint,omitempty"`
	Status          string                     `json:"status"`
}

type trustedCACertificateView struct {
	Subject     string `json:"subject"`
	NotBefore   string `json:"notBefore"`
	NotAfter    string `json:"notAfter"`
	Fingerprint string `json:"fingerprint"`
	Status      string `json:"status"`
}

type issuedMetadata struct {
	ID            string `json:"id"`
	CAID          string `json:"caId"`
	Name          string `json:"name"`
	Role          string `json:"role"`
	Subject       string `json:"subject"`
	SerialNumber  string `json:"serialNumber"`
	IssuedAt      string `json:"issuedAt"`
	NotAfter      string `json:"notAfter"`
	Fingerprint   string `json:"fingerprint"`
	HasPrivateKey bool   `json:"hasPrivateKey"`
}

type issuedView struct {
	issuedMetadata
	CertificatePath   string `json:"certificatePath"`
	PrivateKeyPath    string `json:"privateKeyPath,omitempty"`
	CSRPath           string `json:"csrPath,omitempty"`
	CACertificatePath string `json:"caCertificatePath"`
	Status            string `json:"status"`
}

type csrInspectionView struct {
	Subject            string   `json:"subject"`
	CommonName         string   `json:"commonName"`
	Organizations      []string `json:"organizations,omitempty"`
	DNSNames           []string `json:"dnsNames,omitempty"`
	IPAddresses        []string `json:"ipAddresses,omitempty"`
	EmailAddresses     []string `json:"emailAddresses,omitempty"`
	URIs               []string `json:"uris,omitempty"`
	PublicKeyAlgorithm string   `json:"publicKeyAlgorithm"`
	PublicKeyBits      int      `json:"publicKeyBits"`
	SignatureAlgorithm string   `json:"signatureAlgorithm"`
	Fingerprint        string   `json:"fingerprint"`
	CanSignAsServer    bool     `json:"canSignAsServer"`
}

type inventoryView struct {
	Authorities []authorityView `json:"authorities"`
	Identities  []identityView  `json:"identities"`
	Issued      []issuedView    `json:"issued"`
	Warnings    []string        `json:"warnings,omitempty"`
}
