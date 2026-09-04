// frpc-cert-tool contains host-side helpers for certificate bundles exported
// by FRPC Android. It is deliberately separate from the Android c-shared ABI.
package main

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/gbitcat/frpc-android/native/frpc-cert/internal/portablebackup"
	"golang.org/x/term"
)

const (
	maxArchiveEntries = 16
	maxArchiveFile    = 2 * 1024 * 1024
	maxPasswordBytes  = portablebackup.MaxPasswordBytes
)

var expectedFrptlsFiles = [...]string{
	"README.txt",
	"frps-tls.toml",
	"server-ca.crt",
	"server.crt",
	"server.key",
	"trusted-client-ca.crt",
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "extract-frptls" {
		printUsage(stderr)
		return 2
	}
	flags := flag.NewFlagSet("extract-frptls", flag.ContinueOnError)
	flags.SetOutput(stderr)
	inputPath := flags.String("in", "", "path to the exported .frptls bundle")
	outputPath := flags.String("out", "", "new directory for the extracted files")
	if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 || *inputPath == "" || *outputPath == "" {
		if err == nil {
			fmt.Fprintln(stderr, "both -in and -out are required")
		}
		return 2
	}

	fmt.Fprint(stderr, "Bundle password: ")
	password, err := readPassword(stdin)
	fmt.Fprintln(stderr)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}

	envelope, err := readEnvelope(*inputPath)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
	defer clear(envelope)
	plaintext, err := portablebackup.Decrypt(envelope, password)
	if err != nil {
		fmt.Fprintln(stderr, "error: invalid bundle or password")
		return 1
	}
	defer clear(plaintext)

	if err := extractArchive(plaintext, *outputPath); err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Extracted certificate bundle to %s\n", *outputPath)
	return 0
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: frpc-cert-tool extract-frptls -in BUNDLE.frptls -out NEW_DIRECTORY")
	fmt.Fprintln(w, "The bundle password is read from the first line of standard input.")
}

func readPassword(r io.Reader) (string, error) {
	return readPasswordWithTerminal(r, term.IsTerminal, term.ReadPassword)
}

func readPasswordWithTerminal(
	r io.Reader,
	isTerminal func(int) bool,
	readTerminal func(int) ([]byte, error),
) (string, error) {
	if file, ok := r.(*os.File); ok && isTerminal(int(file.Fd())) {
		password, err := readTerminal(int(file.Fd()))
		defer clearCapacity(password)
		if err != nil {
			return "", errors.New("could not read bundle password")
		}
		return validatePasswordBytes(password)
	}

	password, err := readPasswordLine(r)
	defer clearCapacity(password)
	if err != nil {
		return "", err
	}
	return validatePasswordBytes(password)
}

func readPasswordLine(r io.Reader) ([]byte, error) {
	password := make([]byte, maxPasswordBytes+1)
	length := 0
	for length < len(password) {
		n, err := io.ReadFull(r, password[length:length+1])
		if n > 0 {
			if password[length] == '\n' {
				return password[:length], nil
			}
			length++
		}
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return password[:length], nil
			}
			clear(password)
			return nil, errors.New("could not read bundle password")
		}
	}
	return password, nil
}

func clearCapacity(data []byte) {
	if data != nil {
		clear(data[:cap(data)])
	}
}

func validatePasswordBytes(raw []byte) (string, error) {
	if len(raw) > 0 && raw[len(raw)-1] == '\r' {
		raw = raw[:len(raw)-1]
	}
	if len(raw) < portablebackup.MinPasswordBytes {
		return "", errors.New("bundle password must contain at least 12 UTF-8 bytes")
	}
	if len(raw) > maxPasswordBytes {
		return "", errors.New("bundle password is too long")
	}
	return string(raw), nil
}

func readEnvelope(path string) ([]byte, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("inspect input bundle: %w", err)
	}
	if !pathInfo.Mode().IsRegular() {
		return nil, errors.New("input bundle must be a regular file")
	}
	if pathInfo.Size() <= 0 || pathInfo.Size() > portablebackup.MaxEnvelopeBytes {
		return nil, errors.New("input bundle has an invalid size")
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open input bundle: %w", err)
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect opened input bundle: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || !os.SameFile(pathInfo, openedInfo) {
		return nil, errors.New("input bundle changed while it was being opened")
	}
	if openedInfo.Size() <= 0 || openedInfo.Size() > portablebackup.MaxEnvelopeBytes {
		return nil, errors.New("input bundle has an invalid size")
	}

	data, err := readBoundedEnvelope(file)
	if err != nil {
		return nil, err
	}
	retained := false
	defer func() {
		if !retained {
			clear(data)
		}
	}()
	finalInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("reinspect input bundle: %w", err)
	}
	if !finalInfo.Mode().IsRegular() ||
		!os.SameFile(openedInfo, finalInfo) ||
		finalInfo.Size() != int64(len(data)) {
		return nil, errors.New("input bundle changed while it was being read")
	}
	finalPathInfo, err := os.Lstat(path)
	if err != nil || !finalPathInfo.Mode().IsRegular() || !os.SameFile(openedInfo, finalPathInfo) {
		return nil, errors.New("input bundle path changed while it was being read")
	}
	retained = true
	return data, nil
}

func readBoundedEnvelope(reader io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, portablebackup.MaxEnvelopeBytes+1))
	if err != nil {
		clear(data)
		return nil, fmt.Errorf("read input bundle: %w", err)
	}
	if len(data) == 0 || len(data) > portablebackup.MaxEnvelopeBytes {
		clear(data)
		return nil, errors.New("input bundle has an invalid size")
	}
	return data, nil
}

func extractArchive(plaintext []byte, outputPath string) error {
	if err := preflightZipDirectory(plaintext, maxArchiveEntries); err != nil {
		return err
	}
	reader, err := zip.NewReader(bytes.NewReader(plaintext), int64(len(plaintext)))
	if err != nil {
		return errors.New("decrypted bundle is not a valid ZIP archive")
	}
	if len(reader.File) == 0 || len(reader.File) > maxArchiveEntries {
		return errors.New("bundle contains an invalid number of files")
	}

	outputPath, err = filepath.Abs(outputPath)
	if err != nil {
		return fmt.Errorf("resolve output directory: %w", err)
	}
	if _, err := os.Lstat(outputPath); err == nil {
		return errors.New("output path already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect output path: %w", err)
	}
	parent := filepath.Dir(outputPath)
	parentInfo, err := os.Lstat(parent)
	if err != nil {
		return fmt.Errorf("inspect output parent: %w", err)
	}
	if !parentInfo.IsDir() || parentInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("output parent must be a real directory")
	}

	stage, err := os.MkdirTemp(parent, ".frptls-extract-")
	if err != nil {
		return fmt.Errorf("create staging directory: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(stage)
		}
	}()
	if err := os.Chmod(stage, 0o700); err != nil {
		return fmt.Errorf("secure staging directory: %w", err)
	}

	seen := make(map[string]struct{}, len(reader.File))
	missing := make(map[string]struct{}, len(expectedFrptlsFiles))
	for _, name := range expectedFrptlsFiles {
		missing[name] = struct{}{}
	}
	var declaredTotal uint64
	var actualTotal uint64
	for _, entry := range reader.File {
		name, err := safeArchiveName(entry)
		if err != nil {
			return err
		}
		if _, duplicate := seen[name]; duplicate {
			return fmt.Errorf("bundle contains duplicate file %q", name)
		}
		if _, expected := missing[name]; !expected {
			return fmt.Errorf("bundle contains unexpected file %q", name)
		}
		seen[name] = struct{}{}
		delete(missing, name)
		if entry.UncompressedSize64 > maxArchiveFile {
			return fmt.Errorf("bundle file %q exceeds the size limit", name)
		}
		declaredTotal += entry.UncompressedSize64
		if declaredTotal > portablebackup.MaxPlaintextBytes {
			return errors.New("bundle files exceed the total size limit")
		}

		contents, err := readZipFile(entry)
		if err != nil {
			return fmt.Errorf("read bundle file %q: %w", name, err)
		}
		actualTotal += uint64(len(contents))
		if actualTotal > portablebackup.MaxPlaintextBytes {
			clear(contents)
			return errors.New("bundle files exceed the actual total size limit")
		}
		mode := os.FileMode(0o644)
		if strings.EqualFold(filepath.Ext(name), ".key") {
			mode = 0o600
		}
		if err := writeExclusiveFile(filepath.Join(stage, name), contents, mode); err != nil {
			clear(contents)
			return fmt.Errorf("write bundle file %q: %w", name, err)
		}
		clear(contents)
	}
	if len(missing) != 0 {
		names := make([]string, 0, len(missing))
		for name := range missing {
			names = append(names, name)
		}
		sort.Strings(names)
		return fmt.Errorf("bundle is missing required file(s): %s", strings.Join(names, ", "))
	}

	if err := syncDirectory(stage); err != nil {
		return fmt.Errorf("sync extracted files: %w", err)
	}
	if err := os.Rename(stage, outputPath); err != nil {
		return fmt.Errorf("commit output directory: %w", err)
	}
	committed = true
	if err := syncDirectory(parent); err != nil {
		return fmt.Errorf("sync output parent: %w", err)
	}
	return nil
}

func preflightZipDirectory(data []byte, maxEntries int) error {
	const (
		eocdSignature       = 0x06054b50
		eocdBytes           = 22
		centralSignature    = 0x02014b50
		centralHeaderBytes  = 46
		zip64Locator        = 0x07064b50
		zip64LocatorBytes   = 20
		maximumCommentBytes = 0xffff
	)
	if maxEntries <= 0 || len(data) < eocdBytes {
		return errors.New("bundle ZIP directory is invalid")
	}
	start := len(data) - eocdBytes - maximumCommentBytes
	if start < 0 {
		start = 0
	}
	eocdOffset := -1
	for offset := len(data) - eocdBytes; offset >= start; offset-- {
		if binary.LittleEndian.Uint32(data[offset:offset+4]) != eocdSignature {
			continue
		}
		commentBytes := int(binary.LittleEndian.Uint16(data[offset+20 : offset+22]))
		if offset+eocdBytes+commentBytes == len(data) {
			eocdOffset = offset
			break
		}
	}
	if eocdOffset < 0 {
		return errors.New("bundle ZIP directory is invalid")
	}
	if eocdOffset >= zip64LocatorBytes &&
		binary.LittleEndian.Uint32(data[eocdOffset-zip64LocatorBytes:eocdOffset-zip64LocatorBytes+4]) == zip64Locator {
		return errors.New("ZIP64 bundles are not supported")
	}

	eocd := data[eocdOffset : eocdOffset+eocdBytes]
	disk := binary.LittleEndian.Uint16(eocd[4:6])
	directoryDisk := binary.LittleEndian.Uint16(eocd[6:8])
	entriesOnDisk := binary.LittleEndian.Uint16(eocd[8:10])
	declaredEntries := binary.LittleEndian.Uint16(eocd[10:12])
	directoryBytes := binary.LittleEndian.Uint32(eocd[12:16])
	directoryOffset := binary.LittleEndian.Uint32(eocd[16:20])
	if disk != 0 || directoryDisk != 0 || entriesOnDisk != declaredEntries ||
		declaredEntries == 0xffff || directoryBytes == 0xffffffff || directoryOffset == 0xffffffff ||
		declaredEntries == 0 || int(declaredEntries) > maxEntries {
		return errors.New("bundle contains an invalid number of files")
	}
	directoryStart := uint64(directoryOffset)
	directoryEnd := directoryStart + uint64(directoryBytes)
	if directoryEnd != uint64(eocdOffset) || directoryEnd > uint64(len(data)) {
		return errors.New("bundle ZIP directory is invalid")
	}

	position := directoryStart
	actualEntries := 0
	for position < directoryEnd {
		if directoryEnd-position < centralHeaderBytes {
			return errors.New("bundle ZIP directory is invalid")
		}
		header := data[int(position) : int(position)+centralHeaderBytes]
		if binary.LittleEndian.Uint32(header[:4]) != centralSignature {
			return errors.New("bundle ZIP directory is invalid")
		}
		nameBytes := uint64(binary.LittleEndian.Uint16(header[28:30]))
		extraBytes := uint64(binary.LittleEndian.Uint16(header[30:32]))
		commentBytes := uint64(binary.LittleEndian.Uint16(header[32:34]))
		recordBytes := uint64(centralHeaderBytes) + nameBytes + extraBytes + commentBytes
		if recordBytes > directoryEnd-position {
			return errors.New("bundle ZIP directory is invalid")
		}
		actualEntries++
		if actualEntries > maxEntries {
			return errors.New("bundle contains an invalid number of files")
		}
		position += recordBytes
	}
	if actualEntries != int(declaredEntries) {
		return errors.New("bundle ZIP entry count is inconsistent")
	}
	return nil
}

func safeArchiveName(entry *zip.File) (string, error) {
	name := entry.Name
	if name == "" || strings.ContainsRune(name, '\x00') || strings.Contains(name, "\\") ||
		name != filepath.Base(name) || name == "." || name == ".." {
		return "", fmt.Errorf("bundle contains unsafe path %q", name)
	}
	if entry.FileInfo().IsDir() || !entry.Mode().IsRegular() {
		return "", fmt.Errorf("bundle entry %q is not a regular file", name)
	}
	return name, nil
}

func readZipFile(entry *zip.File) ([]byte, error) {
	r, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer r.Close()
	contents, err := io.ReadAll(io.LimitReader(r, maxArchiveFile+1))
	if err != nil {
		clear(contents)
		return nil, err
	}
	if len(contents) > maxArchiveFile {
		clear(contents)
		return nil, errors.New("file exceeds the size limit")
	}
	return contents, nil
}

func writeExclusiveFile(path string, contents []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	failed := true
	defer func() {
		_ = file.Close()
		if failed {
			_ = os.Remove(path)
		}
	}()
	if _, err := file.Write(contents); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	failed = false
	return nil
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
