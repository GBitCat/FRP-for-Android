package main

import (
	"bytes"
	"errors"
	"testing"
)

func TestParseCertificatesPEMEnforcesCertificateCount(t *testing.T) {
	privateKey, certificatePEM, _, _, err := createCA(
		"certificate-count-test",
		"",
		"ecdsa-p256",
		365,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(privateKey)

	atLimit := bytes.Repeat(certificatePEM, maxCertificatesPerPEM)
	certificates, err := parseCertificatesPEM(atLimit)
	if err != nil {
		t.Fatalf("parse at certificate limit: %v", err)
	}
	if len(certificates) != maxCertificatesPerPEM {
		t.Fatalf("certificate count = %d, want %d", len(certificates), maxCertificatesPerPEM)
	}

	overLimit := bytes.Repeat(certificatePEM, maxCertificatesPerPEM+1)
	_, err = parseCertificatesPEM(overLimit)
	if err == nil {
		t.Fatal("certificate PEM above the count limit succeeded")
	}
	var apiProblem *apiError
	if !errors.As(err, &apiProblem) || apiProblem.Code != "INVALID_CERTIFICATE" {
		t.Fatalf("parse error = %v, want INVALID_CERTIFICATE", err)
	}
}
