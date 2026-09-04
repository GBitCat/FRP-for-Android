package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

const recoveryTestIdentityID = "id-0123456789abcdef01234567"

func TestPrepareRootCompletesActivatedDirectoryReplacement(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tls")
	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "identities", recoveryTestIdentityID)
	mustWriteRecoveryMarker(t, target, "old")
	staging, err := createStagingDir(root, "identities", recoveryTestIdentityID)
	if err != nil {
		t.Fatal(err)
	}
	mustWriteRecoveryMarker(t, staging, "new")
	replacement, err := beginManagedDirectoryReplacement(staging, target)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(replacement.backup); err != nil {
		t.Fatalf("expected rollback artifact: %v", err)
	}

	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	if got := mustReadRecoveryMarker(t, target); got != "new" {
		t.Fatalf("recovered marker = %q, want committed new value", got)
	}
	if _, err := os.Lstat(replacement.backup); !os.IsNotExist(err) {
		t.Fatalf("rollback artifact was not removed: %v", err)
	}
}

func TestPrepareRootRestoresReplacementWithoutVisibleTarget(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tls")
	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	category := filepath.Join(root, "identities")
	target := filepath.Join(category, recoveryTestIdentityID)
	mustWriteRecoveryMarker(t, target, "old")
	rollback := filepath.Join(category, ".rollback-"+recoveryTestIdentityID+"-crash")
	if err := os.Rename(target, rollback); err != nil {
		t.Fatal(err)
	}

	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	if got := mustReadRecoveryMarker(t, target); got != "old" {
		t.Fatalf("restored marker = %q, want old value", got)
	}
	if _, err := os.Lstat(rollback); !os.IsNotExist(err) {
		t.Fatalf("rollback artifact was not consumed: %v", err)
	}
}

func TestPrepareRootRemovesIncompleteAndFailedArtifacts(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tls")
	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	category := filepath.Join(root, "identities")
	target := filepath.Join(category, recoveryTestIdentityID)
	mustWriteRecoveryMarker(t, target, "current")
	pending := filepath.Join(category, ".pending-"+recoveryTestIdentityID+"-crash")
	failed := filepath.Join(category, ".failed-"+recoveryTestIdentityID+"-crash")
	mustWriteRecoveryMarker(t, pending, "incomplete")
	mustWriteRecoveryMarker(t, failed, "discarded")

	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{pending, failed} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("transaction artifact still exists at %s: %v", path, err)
		}
	}
	if got := mustReadRecoveryMarker(t, target); got != "current" {
		t.Fatalf("current target changed to %q", got)
	}
}

func TestPrepareRootFinalizesCommittedDeletionTombstone(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tls")
	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	category := filepath.Join(root, "identities")
	target := filepath.Join(category, recoveryTestIdentityID)
	mustWriteRecoveryMarker(t, target, "sensitive identity")
	tombstone := filepath.Join(category, ".deleting-"+recoveryTestIdentityID+"-crash")
	if err := os.Rename(target, tombstone); err != nil {
		t.Fatal(err)
	}

	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Fatalf("deleted identity was unexpectedly restored: %v", err)
	}
	if _, err := os.Lstat(tombstone); !os.IsNotExist(err) {
		t.Fatalf("deletion tombstone was not finalized: %v", err)
	}
}

func TestPrepareRootRejectsAmbiguousRecovery(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tls")
	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	category := filepath.Join(root, "identities")
	for _, suffix := range []string{"one", "two"} {
		mustWriteRecoveryMarker(
			t,
			filepath.Join(category, ".rollback-"+recoveryTestIdentityID+"-"+suffix),
			"old",
		)
	}

	if _, err := prepareRoot(root); err == nil {
		t.Fatal("ambiguous recovery unexpectedly succeeded")
	}
}

func TestReadLimitedFileEnforcesBoundaryAndRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	boundaryPath := filepath.Join(root, "boundary.pem")
	contents := make([]byte, maxManagedFileBytes)
	for index := range contents {
		contents[index] = 0x41
	}
	if err := os.WriteFile(boundaryPath, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	read, err := readLimitedFile(boundaryPath)
	if err != nil {
		t.Fatalf("read boundary file: %v", err)
	}
	if len(read) != maxManagedFileBytes {
		t.Fatalf("boundary read length = %d", len(read))
	}
	clear(read)
	clear(contents)

	oversizedPath := filepath.Join(root, "oversized.pem")
	oversized, err := os.OpenFile(oversizedPath, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := oversized.Truncate(maxManagedFileBytes + 1); err != nil {
		oversized.Close()
		t.Fatal(err)
	}
	if err := oversized.Close(); err != nil {
		t.Fatal(err)
	}
	if data, err := readLimitedFile(oversizedPath); err == nil || data != nil {
		t.Fatalf("oversized certificate file returned %d bytes, error=%v", len(data), err)
	}

	linkPath := filepath.Join(root, "linked.pem")
	if err := os.Symlink(boundaryPath, linkPath); err != nil {
		t.Fatal(err)
	}
	if data, err := readLimitedFile(linkPath); err == nil || data != nil {
		t.Fatalf("certificate symlink returned %d bytes, error=%v", len(data), err)
	}
}

func TestReadLimitedOpenedFileRejectsPathSwap(t *testing.T) {
	root := t.TempDir()
	expectedPath := filepath.Join(root, "expected.pem")
	replacementPath := filepath.Join(root, "replacement.pem")
	if err := os.WriteFile(expectedPath, []byte("expected"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(replacementPath, []byte("swapped!"), 0o600); err != nil {
		t.Fatal(err)
	}
	expectedInfo, err := os.Lstat(expectedPath)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := os.Open(expectedPath)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	if err := os.Rename(replacementPath, expectedPath); err != nil {
		t.Fatal(err)
	}

	data, err := readLimitedOpenedFile(opened, expectedPath, expectedInfo)
	var typed *apiError
	if data != nil || !errors.As(err, &typed) || typed.Code != "INVALID_FILE" {
		t.Fatalf("swapped certificate file returned %q, error=%v", data, err)
	}
}

func TestMetadataDirectoryAndFilesystemEntryLimits(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tls")
	if _, err := prepareRoot(root); err != nil {
		t.Fatal(err)
	}
	category := filepath.Join(root, "identities")
	for index := 0; index < maxManagedRecordsPerCategory; index++ {
		if err := os.Mkdir(filepath.Join(category, fmt.Sprintf("record-%03d", index)), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	paths, err := metadataDirectories(root, "identities")
	if err != nil || len(paths) != maxManagedRecordsPerCategory {
		t.Fatalf("record boundary returned %d paths, error=%v", len(paths), err)
	}
	if err := ensureManagedRecordCapacity(root, "identities"); err == nil {
		t.Fatal("record creation capacity exceeded without an error")
	}
	if err := os.Mkdir(filepath.Join(category, "record-over-limit"), 0o700); err != nil {
		t.Fatal(err)
	}
	if paths, err := metadataDirectories(root, "identities"); err == nil || paths != nil {
		t.Fatalf("over-limit records returned %d paths, error=%v", len(paths), err)
	}

	entryDirectory := filepath.Join(t.TempDir(), "entries")
	if err := os.Mkdir(entryDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	for index := 0; index < maxCategoryFilesystemEntries; index++ {
		path := filepath.Join(entryDirectory, fmt.Sprintf("entry-%04d", index))
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := readDirectoryEntriesBounded(entryDirectory)
	if err != nil || len(entries) != maxCategoryFilesystemEntries {
		t.Fatalf("entry boundary returned %d entries, error=%v", len(entries), err)
	}
	if err := os.WriteFile(filepath.Join(entryDirectory, "entry-over-limit"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if entries, err := readDirectoryEntriesBounded(entryDirectory); err == nil || entries != nil {
		t.Fatalf("over-limit directory returned %d entries, error=%v", len(entries), err)
	}
}

func mustWriteRecoveryMarker(t *testing.T, directory, value string) {
	t.Helper()
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "marker"), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func mustReadRecoveryMarker(t *testing.T, directory string) string {
	t.Helper()
	value, err := os.ReadFile(filepath.Join(directory, "marker"))
	if err != nil {
		t.Fatal(err)
	}
	return string(value)
}
