package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestHandleJSONRequestAcceptsTwoMaximumManagedInputs(t *testing.T) {
	request := apiRequest{
		APIVersion:     abiVersion,
		Operation:      "request_size_probe",
		Root:           t.TempDir(),
		CertificatePem: strings.Repeat("A", maxManagedFileBytes),
		TrustedCAPem:   strings.Repeat("B", maxManagedFileBytes),
	}
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	if len(raw) <= 1024*1024 {
		t.Fatalf("test request must exceed the previous 1 MiB limit: %d", len(raw))
	}
	if len(raw) > maxRequestBytes {
		t.Fatalf("valid two-file request exceeds maxRequestBytes: %d > %d", len(raw), maxRequestBytes)
	}

	response := handleJSONRequest(string(raw))
	if response.Code != "UNKNOWN_OPERATION" {
		t.Fatalf("request was rejected before dispatch: %#v", response)
	}
}

func TestHandleJSONRequestRejectsOversizedInput(t *testing.T) {
	response := handleJSONRequest(strings.Repeat("x", maxRequestBytes+1))
	if response.OK || response.Code != "INVALID_REQUEST" {
		t.Fatalf("oversized request was not rejected: %#v", response)
	}
}
