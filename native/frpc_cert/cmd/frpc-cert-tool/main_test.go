package main

import (
	"archive/zip"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gbitcat/frpc-android/native/frpc-cert/internal/portablebackup"
)

// dartStoredServerBundleVector was produced by ServerTlsBundle's underlying
// WipeableStoredZipBuilder. Keeping it fixed here detects ZIP metadata or
// schema assumptions that would make an Android export unusable by this tool.
const dartStoredServerBundleVector = "UEsDBBQAAAgAAAwwJF0UPSI/EgAAABIAAAAKAAAAc2VydmVyLmNydHNlcnZlciBjZXJ0aWZpY2F0" +
	"ZVBLAwQUAAAIAAAMMCRdbDSlxAsAAAALAAAACgAAAHNlcnZlci5rZXlwcml2YXRlIGtleVBLAwQU" +
	"AAAIAAAMMCRdEdYmzg0AAAANAAAADQAAAHNlcnZlci1jYS5jcnRzZXJ2ZXIgaXNzdWVyUEsDBBQA" +
	"AAgAAAwwJF0A9bABFAAAABQAAAAVAAAAdHJ1c3RlZC1jbGllbnQtY2EuY3J0dHJ1c3RlZCBjbGll" +
	"bnQgcm9vdHNQSwMEFAAACAAADDAkXSAJIa4aAAAAGgAAAA0AAABmcnBzLXRscy50b21sdHJhbnNw" +
	"b3J0LnRscy5mb3JjZSA9IHRydWVQSwMEFAAACAAADDAkXSuBfZkMAAAADAAAAAoAAABSRUFETUUu" +
	"dHh0aW5zdHJ1Y3Rpb25zUEsBAhQAFAAACAAADDAkXRQ9Ij8SAAAAEgAAAAoAAAAAAAAAAAAAAKQB" +
	"AAAAAHNlcnZlci5jcnRQSwECFAAUAAAIAAAMMCRdbDSlxAsAAAALAAAACgAAAAAAAAAAAAAApAE6" +
	"AAAAc2VydmVyLmtleVBLAQIUABQAAAgAAAwwJF0R1ibODQAAAA0AAAANAAAAAAAAAAAAAACkAW0A" +
	"AABzZXJ2ZXItY2EuY3J0UEsBAhQAFAAACAAADDAkXQD1sAEUAAAAFAAAABUAAAAAAAAAAAAAAKQB" +
	"pQAAAHRydXN0ZWQtY2xpZW50LWNhLmNydFBLAQIUABQAAAgAAAwwJF0gCSGuGgAAABoAAAANAAAA" +
	"AAAAAAAAAACkAewAAABmcnBzLXRscy50b21sUEsBAhQAFAAACAAADDAkXSuBfZkMAAAADAAAAAoA" +
	"AAAAAAAAAAAAAKQBMQEAAFJFQURNRS50eHRQSwUGAAAAAAYABgBhAQAAZQEAAAAA"

func TestExtractDartStoredServerBundleKnownVector(t *testing.T) {
	t.Parallel()
	archive, err := base64.StdEncoding.DecodeString(dartStoredServerBundleVector)
	if err != nil {
		t.Fatal(err)
	}
	outputPath := filepath.Join(t.TempDir(), "frps-tls")
	if err := extractArchive(archive, outputPath); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(outputPath, "server.key")); err != nil || string(got) != "private key" {
		t.Fatalf("Dart vector server key = %q, %v", got, err)
	}
	if mode := mustMode(t, filepath.Join(outputPath, "server.key")).Perm(); mode != 0o600 {
		t.Fatalf("Dart vector key mode = %o, want 600", mode)
	}
}

func TestExtractFrptls(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	bundlePath := filepath.Join(root, "server.frptls")
	archive := testZip(t, validBundleFiles())
	if err := os.WriteFile(bundlePath, testEnvelope(t, archive, "export password"), 0o600); err != nil {
		t.Fatal(err)
	}
	outputPath := filepath.Join(root, "frps-tls")
	var stdout, stderr bytes.Buffer
	if code := run(
		[]string{"extract-frptls", "-in", bundlePath, "-out", outputPath},
		strings.NewReader("export password\n"),
		&stdout,
		&stderr,
	); code != 0 {
		t.Fatalf("exit code = %d; stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if mode := mustMode(t, outputPath).Perm(); mode != 0o700 {
		t.Fatalf("output mode = %o, want 700", mode)
	}
	if mode := mustMode(t, filepath.Join(outputPath, "server.key")).Perm(); mode != 0o600 {
		t.Fatalf("key mode = %o, want 600", mode)
	}
	if got, err := os.ReadFile(filepath.Join(outputPath, "server.key")); err != nil || string(got) != "private key" {
		t.Fatalf("server key = %q, %v", got, err)
	}

	stdout.Reset()
	stderr.Reset()
	if code := run(
		[]string{"extract-frptls", "-in", bundlePath, "-out", outputPath},
		strings.NewReader("export password\n"),
		&stdout,
		&stderr,
	); code == 0 || !strings.Contains(stderr.String(), "already exists") {
		t.Fatalf("second extraction code=%d stderr=%q", code, stderr.String())
	}
}

func TestExtractFrptlsRequiresExactBundleSchema(t *testing.T) {
	t.Parallel()
	tests := map[string]map[string]string{
		"missing file": func() map[string]string {
			files := validBundleFiles()
			delete(files, "trusted-client-ca.crt")
			return files
		}(),
		"unexpected file": func() map[string]string {
			files := validBundleFiles()
			files["extra.txt"] = "unexpected"
			return files
		}(),
	}
	for name, files := range tests {
		name, files := name, files
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			bundlePath := filepath.Join(root, "invalid.frptls")
			if err := os.WriteFile(
				bundlePath,
				testEnvelope(t, testZip(t, files), "export password"),
				0o600,
			); err != nil {
				t.Fatal(err)
			}
			outputPath := filepath.Join(root, "frps-tls")
			var stdout, stderr bytes.Buffer
			if code := run(
				[]string{"extract-frptls", "-in", bundlePath, "-out", outputPath},
				strings.NewReader("export password\n"),
				&stdout,
				&stderr,
			); code == 0 {
				t.Fatalf("invalid schema succeeded: stdout=%q stderr=%q", stdout.String(), stderr.String())
			}
			if _, err := os.Lstat(outputPath); !os.IsNotExist(err) {
				t.Fatalf("destination must remain absent, err=%v", err)
			}
		})
	}
}

func TestExtractFrptlsRejectsTraversalAndKeepsDestinationAbsent(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	bundlePath := filepath.Join(root, "unsafe.frptls")
	archive := testZip(t, map[string]string{"../server.key": "private key"})
	if err := os.WriteFile(bundlePath, testEnvelope(t, archive, "export password"), 0o600); err != nil {
		t.Fatal(err)
	}
	outputPath := filepath.Join(root, "frps-tls")
	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"extract-frptls", "-in", bundlePath, "-out", outputPath},
		strings.NewReader("export password\n"),
		&stdout,
		&stderr,
	)
	if code == 0 || !strings.Contains(stderr.String(), "unsafe path") {
		t.Fatalf("exit code=%d stderr=%q", code, stderr.String())
	}
	if _, err := os.Lstat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("destination must remain absent, err=%v", err)
	}
}

func TestExtractFrptlsRejectsWrongPassword(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	bundlePath := filepath.Join(root, "server.frptls")
	archive := testZip(t, map[string]string{"server.key": "private key"})
	if err := os.WriteFile(bundlePath, testEnvelope(t, archive, "correct password"), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"extract-frptls", "-in", bundlePath, "-out", filepath.Join(root, "out")},
		strings.NewReader("wrong password\n"),
		&stdout,
		&stderr,
	)
	if code == 0 || !strings.Contains(stderr.String(), "invalid bundle or password") {
		t.Fatalf("exit code=%d stderr=%q", code, stderr.String())
	}
}

func TestReadPasswordUsesTerminalNoEchoReader(t *testing.T) {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer read.Close()
	defer write.Close()

	terminalPassword := []byte("terminal password")
	terminalCalled := false
	got, err := readPasswordWithTerminal(
		read,
		func(fd int) bool { return fd == int(read.Fd()) },
		func(fd int) ([]byte, error) {
			if fd != int(read.Fd()) {
				t.Fatalf("terminal fd = %d, want %d", fd, read.Fd())
			}
			terminalCalled = true
			return terminalPassword, nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !terminalCalled {
		t.Fatal("terminal password reader was not called")
	}
	if got != "terminal password" {
		t.Fatalf("password = %q", got)
	}
	for index, value := range terminalPassword {
		if value != 0 {
			t.Fatalf("terminal password byte %d was not cleared", index)
		}
	}
}

func TestReadPasswordFallsBackToFirstNonTerminalLine(t *testing.T) {
	got, err := readPasswordWithTerminal(
		strings.NewReader("export password\r\nignored"),
		func(int) bool { return false },
		func(int) ([]byte, error) {
			t.Fatal("terminal password reader was called for a non-terminal")
			return nil, nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if got != "export password" {
		t.Fatalf("password = %q", got)
	}
}

func TestReadBoundedEnvelopeRejectsOversizedReaderAndFile(t *testing.T) {
	oversized := bytes.NewReader(make([]byte, portablebackup.MaxEnvelopeBytes+1))
	if data, err := readBoundedEnvelope(oversized); err == nil || data != nil {
		t.Fatalf("oversized reader returned data=%d bytes, error=%v", len(data), err)
	}

	path := filepath.Join(t.TempDir(), "oversized.frptls")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(portablebackup.MaxEnvelopeBytes + 1); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if data, err := readEnvelope(path); err == nil || data != nil {
		t.Fatalf("oversized file returned data=%d bytes, error=%v", len(data), err)
	}
}

func TestReadEnvelopeRejectsSymbolicLink(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target.frptls")
	if err := os.WriteFile(target, []byte("not empty"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link.frptls")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}

	if data, err := readEnvelope(link); err == nil || data != nil {
		t.Fatalf("symbolic link returned data=%d bytes, error=%v", len(data), err)
	}
}

func TestPreflightZipDirectoryRejectsHiddenEntryCount(t *testing.T) {
	archive := testZipEntryCount(t, maxArchiveEntries+1)
	eocdOffset := len(archive) - 22
	binary.LittleEndian.PutUint16(archive[eocdOffset+8:eocdOffset+10], 1)
	binary.LittleEndian.PutUint16(archive[eocdOffset+10:eocdOffset+12], 1)

	err := preflightZipDirectory(archive, maxArchiveEntries)
	if err == nil || !strings.Contains(err.Error(), "invalid number of files") {
		t.Fatalf("preflight error = %v", err)
	}
}

func TestPreflightZipDirectoryRejectsZip64(t *testing.T) {
	archive := testZipEntryCount(t, 1)
	eocdOffset := len(archive) - 22
	binary.LittleEndian.PutUint16(archive[eocdOffset+8:eocdOffset+10], 0xffff)
	binary.LittleEndian.PutUint16(archive[eocdOffset+10:eocdOffset+12], 0xffff)

	err := preflightZipDirectory(archive, maxArchiveEntries)
	if err == nil || !strings.Contains(err.Error(), "invalid number of files") {
		t.Fatalf("preflight error = %v", err)
	}
}

func mustMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode()
}

func testZip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for name, contents := range files {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(contents)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func testZipEntryCount(t *testing.T, count int) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for index := 0; index < count; index++ {
		entry, err := writer.Create("duplicate")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write(nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func validBundleFiles() map[string]string {
	return map[string]string{
		"README.txt":            "instructions",
		"frps-tls.toml":         "transport.tls.force = true",
		"server-ca.crt":         "server issuer",
		"server.crt":            "server certificate",
		"server.key":            "private key",
		"trusted-client-ca.crt": "trusted client roots",
	}
}

func testEnvelope(t *testing.T, plaintext []byte, password string) []byte {
	t.Helper()
	const fixedHeaderBytes = 12
	const iterations = 600_000
	salt := []byte("0123456789abcdef")
	nonce := []byte("abcdefghijkl")
	header := make([]byte, fixedHeaderBytes+len(salt)+len(nonce))
	copy(header, "FRPB")
	header[4] = portablebackup.Version
	header[5] = portablebackup.KDFPBKDF2SHA256
	binary.BigEndian.PutUint32(header[6:10], iterations)
	header[10] = byte(len(salt))
	header[11] = byte(len(nonce))
	copy(header[fixedHeaderBytes:], salt)
	copy(header[fixedHeaderBytes+len(salt):], nonce)
	key, err := pbkdf2.Key(sha256.New, password, salt, iterations, 32)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	return aead.Seal(header, nonce, plaintext, header)
}
