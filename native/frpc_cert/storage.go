package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

const (
	maxManagedFileBytes          = 2 * 1024 * 1024
	maxManagedRecordsPerCategory = 256
	maxCategoryFilesystemEntries = 1024
	directoryReadBatchSize       = 64
)

var managedIDPattern = regexp.MustCompile(`^[a-z]+-[a-f0-9]{24}$`)

type managedFileUpdate struct {
	Data []byte
	Mode os.FileMode
}

type managedDirectoryReplacement struct {
	target string
	backup string
	active bool
}

func prepareRoot(raw string) (string, error) {
	if strings.TrimSpace(raw) == "" || !filepath.IsAbs(raw) {
		return "", problem("PATH_REJECTED", "certificate storage root must be absolute")
	}
	root := filepath.Clean(raw)
	if info, err := os.Lstat(root); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return "", problem("PATH_REJECTED", "certificate storage root is not a regular directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", problem("IO_ERROR", "unable to inspect certificate storage", err)
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", problem("IO_ERROR", "unable to create certificate storage", err)
	}
	if err := ensurePrivateDirectory(root); err != nil {
		return "", err
	}
	for _, category := range []struct {
		name   string
		prefix string
	}{
		{name: "authorities", prefix: "ca"},
		{name: "identities", prefix: "id"},
		{name: "issued", prefix: "cert"},
	} {
		path := filepath.Join(root, category.name)
		if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return "", problem("IO_ERROR", "unable to initialize certificate storage", err)
		}
		if err := ensurePrivateDirectory(path); err != nil {
			return "", err
		}
		if err := recoverManagedTransactions(path, category.prefix); err != nil {
			return "", err
		}
	}
	return root, nil
}

type managedRecoveryArtifacts struct {
	rollbacks []string
	failed    []string
}

// recoverManagedTransactions resolves directory-swap states left behind if
// the process was killed between atomic renames. A visible target is the
// replacement commit point. A .deleting tombstone is itself the deletion
// commit point and is always finalized rather than restored.
func recoverManagedTransactions(categoryPath, idPrefix string) error {
	entries, err := readDirectoryEntriesBounded(categoryPath)
	if err != nil {
		return err
	}
	artifacts := map[string]*managedRecoveryArtifacts{}
	changed := false
	for _, entry := range entries {
		name := entry.Name()
		kind := ""
		for _, candidate := range []string{"pending", "rollback", "failed", "deleting"} {
			if strings.HasPrefix(name, "."+candidate+"-") {
				kind = candidate
				break
			}
		}
		if kind == "" {
			continue
		}
		id, ok := recoveryArtifactID(name, kind, idPrefix)
		if !ok {
			return problem("PATH_REJECTED", "certificate storage contains an invalid transaction artifact")
		}
		path := filepath.Join(categoryPath, name)
		if err := ensureRecoveryDirectory(path); err != nil {
			return err
		}
		if kind == "pending" || kind == "deleting" {
			if err := os.RemoveAll(path); err != nil {
				return problem("IO_ERROR", "unable to finalize certificate transaction", err)
			}
			changed = true
			continue
		}
		entryArtifacts := artifacts[id]
		if entryArtifacts == nil {
			entryArtifacts = &managedRecoveryArtifacts{}
			artifacts[id] = entryArtifacts
		}
		if kind == "rollback" {
			entryArtifacts.rollbacks = append(entryArtifacts.rollbacks, path)
		} else {
			entryArtifacts.failed = append(entryArtifacts.failed, path)
		}
	}

	ids := make([]string, 0, len(artifacts))
	for id := range artifacts {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		entryArtifacts := artifacts[id]
		target := filepath.Join(categoryPath, id)
		targetExists, err := safeManagedDirectoryExists(target)
		if err != nil {
			return err
		}

		if len(entryArtifacts.rollbacks) > 0 {
			if targetExists {
				for _, path := range entryArtifacts.rollbacks {
					if err := os.RemoveAll(path); err != nil {
						return problem("IO_ERROR", "unable to finalize recovered certificate transaction", err)
					}
					changed = true
				}
			} else {
				if len(entryArtifacts.rollbacks) != 1 {
					return problem("IO_ERROR", "certificate transaction recovery is ambiguous")
				}
				if err := os.Rename(entryArtifacts.rollbacks[0], target); err != nil {
					return problem("IO_ERROR", "unable to restore certificate transaction", err)
				}
				targetExists = true
				changed = true
			}
		}

		if len(entryArtifacts.failed) > 0 {
			if targetExists {
				for _, path := range entryArtifacts.failed {
					if err := os.RemoveAll(path); err != nil {
						return problem("IO_ERROR", "unable to remove failed certificate transaction", err)
					}
					changed = true
				}
			} else {
				if len(entryArtifacts.failed) != 1 {
					return problem("IO_ERROR", "certificate transaction recovery is ambiguous")
				}
				if err := os.Rename(entryArtifacts.failed[0], target); err != nil {
					return problem("IO_ERROR", "unable to restore failed certificate transaction", err)
				}
				changed = true
			}
		}
	}
	if changed {
		return syncDirectory(categoryPath)
	}
	return nil
}

func recoveryArtifactID(name, kind, idPrefix string) (string, bool) {
	value := strings.TrimPrefix(name, "."+kind+"-")
	idLength := len(idPrefix) + 1 + 24
	if len(value) <= idLength || value[idLength] != '-' {
		return "", false
	}
	id := value[:idLength]
	suffix := value[idLength+1:]
	if validateManagedID(id, idPrefix) != nil || suffix == "" {
		return "", false
	}
	for _, character := range suffix {
		if (character < 'a' || character > 'z') &&
			(character < 'A' || character > 'Z') &&
			(character < '0' || character > '9') {
			return "", false
		}
	}
	return id, true
}

func ensureRecoveryDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return problem("IO_ERROR", "unable to inspect certificate transaction", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return problem("PATH_REJECTED", "certificate transaction artifact is unsafe")
	}
	return nil
}

func safeManagedDirectoryExists(path string) (bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, problem("IO_ERROR", "unable to inspect recovered certificate", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return false, problem("PATH_REJECTED", "recovered certificate path is unsafe")
	}
	return true, nil
}

func ensurePrivateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return problem("IO_ERROR", "unable to inspect certificate storage", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return problem("PATH_REJECTED", "certificate storage contains an unsafe directory")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return problem("IO_ERROR", "unable to protect certificate storage", err)
	}
	return nil
}

func newManagedID(prefix string) (string, error) {
	random := make([]byte, 12)
	if _, err := rand.Read(random); err != nil {
		return "", problem("RANDOM_FAILED", "unable to generate a secure identifier", err)
	}
	return prefix + "-" + hex.EncodeToString(random), nil
}

func validateManagedID(id, prefix string) error {
	if !managedIDPattern.MatchString(id) || !strings.HasPrefix(id, prefix+"-") {
		return problem("INVALID_ID", "managed certificate identifier is invalid")
	}
	return nil
}

func validateManagedDirectoryID(directory, id, prefix string) error {
	if err := validateManagedID(id, prefix); err != nil {
		return problem("INVALID_METADATA", "managed certificate metadata contains an invalid ID")
	}
	if filepath.Base(filepath.Clean(directory)) != id {
		return problem("INVALID_METADATA", "managed certificate ID does not match its directory")
	}
	return nil
}

func managedDir(root, category, id, prefix string) (string, error) {
	if err := validateManagedID(id, prefix); err != nil {
		return "", err
	}
	base := filepath.Join(root, category)
	path := filepath.Join(base, id)
	relative, err := filepath.Rel(base, path)
	if err != nil || strings.HasPrefix(relative, "..") || filepath.IsAbs(relative) {
		return "", problem("PATH_REJECTED", "managed certificate path escaped its storage area")
	}
	return path, nil
}

func createStagingDir(root, category, id string) (string, error) {
	base := filepath.Join(root, category)
	path, err := os.MkdirTemp(base, ".pending-"+id+"-")
	if err != nil {
		return "", problem("IO_ERROR", "unable to create certificate staging directory", err)
	}
	if err := os.Chmod(path, 0o700); err != nil {
		_ = os.RemoveAll(path)
		return "", problem("IO_ERROR", "unable to protect certificate staging directory", err)
	}
	return path, nil
}

func commitStagingDir(staging, target string) error {
	if _, err := os.Lstat(target); err == nil {
		return problem("ALREADY_EXISTS", "managed certificate already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return problem("IO_ERROR", "unable to inspect certificate destination", err)
	}
	if err := os.Rename(staging, target); err != nil {
		return problem("IO_ERROR", "unable to commit certificate files", err)
	}
	return syncDirectory(filepath.Dir(target))
}

func stageManagedDirectoryUpdate(
	root, category, id, prefix string,
	updates map[string]managedFileUpdate,
) (string, string, error) {
	target, err := managedDir(root, category, id, prefix)
	if err != nil {
		return "", "", err
	}
	info, err := os.Lstat(target)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", "", problem("NOT_FOUND", "managed certificate was not found")
		}
		return "", "", problem("IO_ERROR", "unable to inspect managed certificate", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", "", problem("PATH_REJECTED", "managed certificate path is unsafe")
	}
	staging, err := createStagingDir(root, category, id)
	if err != nil {
		return "", "", err
	}
	failed := true
	defer func() {
		if failed {
			_ = os.RemoveAll(staging)
		}
	}()
	entries, err := readDirectoryEntriesBounded(target)
	if err != nil {
		return "", "", err
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".pending-") || strings.HasPrefix(entry.Name(), ".rollback-") {
			continue
		}
		entryInfo, err := entry.Info()
		if err != nil {
			return "", "", problem("IO_ERROR", "unable to inspect managed certificate file", err)
		}
		if !entryInfo.Mode().IsRegular() || entryInfo.Mode()&os.ModeSymlink != 0 ||
			entry.Name() != filepath.Base(entry.Name()) {
			return "", "", problem("PATH_REJECTED", "managed certificate directory contains an unsafe entry")
		}
		data, err := readLimitedFile(filepath.Join(target, entry.Name()))
		if err != nil {
			return "", "", err
		}
		mode := entryInfo.Mode().Perm()
		if mode != 0o600 && mode != 0o644 {
			mode = 0o600
		}
		if err := atomicWrite(filepath.Join(staging, entry.Name()), data, mode); err != nil {
			clear(data)
			return "", "", err
		}
		clear(data)
	}
	for name, update := range updates {
		if name == "" || name != filepath.Base(name) || strings.HasPrefix(name, ".") {
			return "", "", problem("INVALID_FILE", "managed update filename is invalid")
		}
		if update.Mode != 0o600 && update.Mode != 0o644 {
			return "", "", problem("INVALID_FILE", "managed update file mode is invalid")
		}
		if err := atomicWrite(filepath.Join(staging, name), update.Data, update.Mode); err != nil {
			return "", "", err
		}
	}
	if err := syncDirectory(staging); err != nil {
		return "", "", err
	}
	failed = false
	return staging, target, nil
}

func beginManagedDirectoryReplacement(staging, target string) (*managedDirectoryReplacement, error) {
	parent := filepath.Dir(target)
	placeholder, err := os.MkdirTemp(parent, ".rollback-"+filepath.Base(target)+"-")
	if err != nil {
		return nil, problem("IO_ERROR", "unable to create certificate rollback path", err)
	}
	if err := os.Remove(placeholder); err != nil {
		return nil, problem("IO_ERROR", "unable to prepare certificate rollback path", err)
	}
	if err := os.Rename(target, placeholder); err != nil {
		return nil, problem("IO_ERROR", "unable to stage existing certificate files", err)
	}
	replacement := &managedDirectoryReplacement{
		target: target,
		backup: placeholder,
		active: true,
	}
	if err := os.Rename(staging, target); err != nil {
		if restoreErr := os.Rename(placeholder, target); restoreErr != nil {
			return replacement, problem(
				"IO_ERROR",
				"unable to activate or restore certificate files",
				errors.Join(err, restoreErr),
			)
		}
		replacement.active = false
		return nil, problem("IO_ERROR", "unable to activate certificate files", err)
	}
	if err := syncDirectory(parent); err != nil {
		if rollbackErr := replacement.rollback(); rollbackErr != nil {
			return replacement, problem(
				"IO_ERROR",
				"unable to flush or roll back certificate files",
				errors.Join(err, rollbackErr),
			)
		}
		return nil, err
	}
	return replacement, nil
}

func (replacement *managedDirectoryReplacement) finalize() error {
	if replacement == nil || !replacement.active {
		return nil
	}
	if err := os.RemoveAll(replacement.backup); err != nil {
		return problem("IO_ERROR", "unable to remove certificate rollback data", err)
	}
	if err := syncDirectory(filepath.Dir(replacement.target)); err != nil {
		return err
	}
	replacement.active = false
	return nil
}

func (replacement *managedDirectoryReplacement) rollback() error {
	if replacement == nil || !replacement.active {
		return nil
	}
	parent := filepath.Dir(replacement.target)
	failedPath, err := os.MkdirTemp(parent, ".failed-"+filepath.Base(replacement.target)+"-")
	if err != nil {
		return problem("IO_ERROR", "unable to prepare certificate rollback", err)
	}
	if err := os.Remove(failedPath); err != nil {
		return problem("IO_ERROR", "unable to prepare certificate rollback", err)
	}
	if err := os.Rename(replacement.target, failedPath); err != nil {
		return problem("IO_ERROR", "unable to move failed certificate update", err)
	}
	if err := os.Rename(replacement.backup, replacement.target); err != nil {
		_ = os.Rename(failedPath, replacement.target)
		return problem("IO_ERROR", "unable to restore previous certificate files", err)
	}
	replacement.active = false
	if err := syncDirectory(parent); err != nil {
		return err
	}
	if err := os.RemoveAll(failedPath); err != nil {
		return problem("IO_ERROR", "unable to remove failed certificate update", err)
	}
	return syncDirectory(parent)
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	if len(data) == 0 || len(data) > maxManagedFileBytes {
		return problem("INVALID_FILE", "certificate file size is invalid")
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return problem("IO_ERROR", "unable to create certificate directory", err)
	}
	file, err := os.CreateTemp(directory, ".pending-")
	if err != nil {
		return problem("IO_ERROR", "unable to create certificate file", err)
	}
	temporary := file.Name()
	committed := false
	defer func() {
		_ = file.Close()
		if !committed {
			_ = os.Remove(temporary)
		}
	}()
	if err := file.Chmod(mode); err != nil {
		return problem("IO_ERROR", "unable to protect certificate file", err)
	}
	if _, err := file.Write(data); err != nil {
		return problem("IO_ERROR", "unable to write certificate file", err)
	}
	if err := file.Sync(); err != nil {
		return problem("IO_ERROR", "unable to flush certificate file", err)
	}
	if err := file.Close(); err != nil {
		return problem("IO_ERROR", "unable to close certificate file", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		return problem("IO_ERROR", "unable to replace certificate file", err)
	}
	committed = true
	return syncDirectory(directory)
}

func writeJSON(path string, value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return problem("INTERNAL_ERROR", "unable to encode certificate metadata", err)
	}
	encoded = append(encoded, '\n')
	return atomicWrite(path, encoded, 0o600)
}

func readJSON(path string, target any) error {
	raw, err := readLimitedFile(path)
	if err != nil {
		return err
	}
	defer clear(raw)
	if err := json.Unmarshal(raw, target); err != nil {
		return problem("INVALID_METADATA", "certificate metadata is damaged", err)
	}
	return nil
}

func readLimitedFile(path string) ([]byte, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, problem("NOT_FOUND", "certificate file was not found")
		}
		return nil, problem("IO_ERROR", "unable to inspect certificate file", err)
	}
	if !pathInfo.Mode().IsRegular() || pathInfo.Size() <= 0 || pathInfo.Size() > maxManagedFileBytes {
		return nil, problem("INVALID_FILE", "certificate file is not a safe regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, problem("IO_ERROR", "unable to open certificate file", err)
	}
	defer file.Close()
	return readLimitedOpenedFile(file, path, pathInfo)
}

func readLimitedOpenedFile(file *os.File, path string, pathInfo os.FileInfo) ([]byte, error) {
	openedInfo, err := file.Stat()
	if err != nil {
		return nil, problem("IO_ERROR", "unable to inspect opened certificate file", err)
	}
	if !openedInfo.Mode().IsRegular() ||
		!os.SameFile(pathInfo, openedInfo) ||
		openedInfo.Size() <= 0 ||
		openedInfo.Size() > maxManagedFileBytes {
		return nil, problem("INVALID_FILE", "certificate file changed while it was being opened")
	}
	data, err := io.ReadAll(io.LimitReader(file, maxManagedFileBytes+1))
	if err != nil || len(data) == 0 || len(data) > maxManagedFileBytes {
		clear(data)
		return nil, problem("INVALID_FILE", "unable to read certificate file safely", err)
	}
	retained := false
	defer func() {
		if !retained {
			clear(data)
		}
	}()
	finalInfo, err := file.Stat()
	if err != nil {
		return nil, problem("IO_ERROR", "unable to reinspect certificate file", err)
	}
	if !finalInfo.Mode().IsRegular() ||
		!os.SameFile(openedInfo, finalInfo) ||
		finalInfo.Size() != int64(len(data)) {
		return nil, problem("INVALID_FILE", "certificate file changed while it was being read")
	}
	finalPathInfo, err := os.Lstat(path)
	if err != nil || !finalPathInfo.Mode().IsRegular() || !os.SameFile(openedInfo, finalPathInfo) {
		return nil, problem("INVALID_FILE", "certificate file path changed while it was being read", err)
	}
	retained = true
	return data, nil
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return problem("IO_ERROR", "unable to open certificate directory", err)
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return problem("IO_ERROR", "unable to flush certificate directory", err)
	}
	return nil
}

func metadataDirectories(root, category string) ([]string, error) {
	entries, err := readDirectoryEntriesBounded(filepath.Join(root, category))
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0, min(len(entries), maxManagedRecordsPerCategory))
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".pending-") {
			if len(paths) >= maxManagedRecordsPerCategory {
				return nil, problem(
					"LIMIT_EXCEEDED",
					"certificate storage contains too many managed records",
				)
			}
			paths = append(paths, filepath.Join(root, category, entry.Name()))
		}
	}
	sort.Strings(paths)
	return paths, nil
}

func ensureManagedRecordCapacity(root, category string) error {
	paths, err := metadataDirectories(root, category)
	if err != nil {
		return err
	}
	if len(paths) >= maxManagedRecordsPerCategory {
		return problem(
			"LIMIT_EXCEEDED",
			"certificate storage has reached its managed record limit",
		)
	}
	return nil
}

// readDirectoryEntriesBounded avoids os.ReadDir's all-at-once allocation and
// also bounds work spent scanning unexpected files in app-private storage.
func readDirectoryEntriesBounded(path string) ([]os.DirEntry, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return nil, problem("IO_ERROR", "unable to inspect certificate storage directory", err)
	}
	if !pathInfo.IsDir() || pathInfo.Mode()&os.ModeSymlink != 0 {
		return nil, problem("PATH_REJECTED", "certificate storage directory is unsafe")
	}
	directory, err := os.Open(path)
	if err != nil {
		return nil, problem("IO_ERROR", "unable to open certificate storage directory", err)
	}
	defer directory.Close()
	openedInfo, err := directory.Stat()
	if err != nil {
		return nil, problem("IO_ERROR", "unable to inspect opened certificate storage directory", err)
	}
	if !openedInfo.IsDir() || !os.SameFile(pathInfo, openedInfo) {
		return nil, problem("PATH_REJECTED", "certificate storage directory changed while opening")
	}

	entries := make([]os.DirEntry, 0, directoryReadBatchSize)
	for {
		batch, readErr := directory.ReadDir(directoryReadBatchSize)
		if len(entries)+len(batch) > maxCategoryFilesystemEntries {
			return nil, problem(
				"LIMIT_EXCEEDED",
				"certificate storage directory contains too many entries",
			)
		}
		entries = append(entries, batch...)
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return nil, problem("IO_ERROR", "unable to read certificate storage directory", readErr)
		}
	}
	finalInfo, err := directory.Stat()
	if err != nil {
		return nil, problem("IO_ERROR", "unable to reinspect certificate storage directory", err)
	}
	if !finalInfo.IsDir() || !os.SameFile(openedInfo, finalInfo) {
		return nil, problem("PATH_REJECTED", "certificate storage directory changed while reading")
	}
	finalPathInfo, err := os.Lstat(path)
	if err != nil || !finalPathInfo.IsDir() ||
		finalPathInfo.Mode()&os.ModeSymlink != 0 ||
		!os.SameFile(openedInfo, finalPathInfo) {
		return nil, problem("PATH_REJECTED", "certificate storage directory path changed while reading", err)
	}
	return entries, nil
}

func safeRemoveManaged(root, category, id, prefix string) error {
	path, err := managedDir(root, category, id, prefix)
	if err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return problem("NOT_FOUND", "managed certificate was not found")
		}
		return problem("IO_ERROR", "unable to inspect managed certificate", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return problem("PATH_REJECTED", "managed certificate path is unsafe")
	}
	parent := filepath.Dir(path)
	tombstone, err := os.MkdirTemp(parent, ".deleting-"+filepath.Base(path)+"-")
	if err != nil {
		return problem("IO_ERROR", "unable to prepare managed certificate deletion", err)
	}
	if err := os.Remove(tombstone); err != nil {
		return problem("IO_ERROR", "unable to prepare managed certificate deletion", err)
	}
	if err := os.Rename(path, tombstone); err != nil {
		return problem("IO_ERROR", "unable to commit managed certificate deletion", err)
	}
	// The rename is the logical commit point. Recovery removes the tombstone
	// after a crash and never resurrects a successfully deleted credential.
	if err := syncDirectory(parent); err != nil {
		return err
	}
	if err := os.RemoveAll(tombstone); err != nil {
		return problem("IO_ERROR", "unable to finalize managed certificate deletion", err)
	}
	if err := syncDirectory(parent); err != nil {
		return err
	}
	return nil
}

func validateDisplayText(value, field string, required bool) (string, error) {
	value = strings.TrimSpace(value)
	if required && value == "" {
		return "", problem("INVALID_REQUEST", field+" is required")
	}
	if len(value) > 128 || containsControl(value) {
		return "", problem("INVALID_REQUEST", field+" is invalid")
	}
	return value, nil
}

func containsControl(value string) bool {
	for _, character := range value {
		if unicode.IsControl(character) {
			return true
		}
	}
	return false
}

func formatWarning(path string, err error) string {
	return fmt.Sprintf("%s: %s", filepath.Base(path), err.Error())
}
