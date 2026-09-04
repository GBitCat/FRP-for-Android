package main

import (
	"crypto"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestRealFrpMutualTLS is opt-in because it executes the exact frpc/frps
// binaries prepared by scripts/test_mtls_e2e.sh. The ordinary unit-test run
// skips it; CI and scripts/test.sh run it explicitly with pinned binaries.
func TestRealFrpMutualTLS(t *testing.T) {
	frpcPath := os.Getenv("FRP_E2E_FRPC")
	frpsPath := os.Getenv("FRP_E2E_FRPS")
	if frpcPath == "" || frpsPath == "" {
		t.Skip("real frpc/frps binaries were not provided")
	}
	for _, path := range []string{frpcPath, frpsPath} {
		if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() || info.Mode()&0o111 == 0 {
			t.Fatalf("invalid e2e binary %q: %v", path, err)
		}
	}

	work := t.TempDir()
	serverCA := createE2EAuthority(t, "server-ca")
	clientCA := createE2EAuthority(t, "client-ca")
	rogueCA := createE2EAuthority(t, "rogue-client-ca")
	server := createE2ELeaf(t, "frps.local", []string{"frps.local"}, serverCA, "server")
	client := createE2ELeaf(t, "android-client", nil, clientCA, "client")
	rogueClient := createE2ELeaf(t, "rogue-client", nil, rogueCA, "client")

	paths := map[string]string{}
	write := func(name string, data []byte, mode os.FileMode) string {
		t.Helper()
		path := filepath.Join(work, name)
		if err := atomicWrite(path, data, mode); err != nil {
			t.Fatal(err)
		}
		paths[name] = path
		return path
	}
	write("server-ca.crt", serverCA.certificatePEM, 0o644)
	write("client-ca.crt", clientCA.certificatePEM, 0o644)
	write("rogue-ca.crt", rogueCA.certificatePEM, 0o644)
	write("server.crt", server.certificatePEM, 0o644)
	write("server.key", server.privateKeyPEM, 0o600)
	write("client.crt", client.certificatePEM, 0o644)
	write("client.key", client.privateKeyPEM, 0o600)
	write("rogue-client.crt", rogueClient.certificatePEM, 0o644)
	write("rogue-client.key", rogueClient.privateKeyPEM, 0o600)

	port := reserveE2EPort(t)
	serverConfig := filepath.Join(work, "frps.toml")
	writeE2EConfig(t, serverConfig, fmt.Sprintf(`
bindAddr = "127.0.0.1"
bindPort = %d
transport.tls.force = true
transport.tls.certFile = %s
transport.tls.keyFile = %s
transport.tls.trustedCaFile = %s
log.to = "console"
log.level = "trace"
log.disablePrintColor = true
`, port, tomlQuote(paths["server.crt"]), tomlQuote(paths["server.key"]), tomlQuote(paths["client-ca.crt"])))
	verifyE2EConfig(t, frpsPath, serverConfig)

	frpsLog := filepath.Join(work, "frps.log")
	frps := startE2EProcess(t, frpsPath, serverConfig, frpsLog)
	t.Cleanup(frps.stop)
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("frps log:\n%s", readE2ELog(frpsLog))
		}
	})
	waitForE2EPort(t, port, frps)
	probeE2ETLS(
		t,
		port,
		paths["client.crt"],
		paths["client.key"],
		paths["server-ca.crt"],
	)

	clientConfig := func(name, certPath, keyPath, trustedCAPath string) string {
		path := filepath.Join(work, name+".toml")
		writeE2EConfig(t, path, fmt.Sprintf(`
serverAddr = "127.0.0.1"
serverPort = %d
loginFailExit = true
transport.protocol = "tcp"
transport.tls.enable = true
transport.tls.serverName = "frps.local"
transport.tls.certFile = %s
transport.tls.keyFile = %s
transport.tls.trustedCaFile = %s
log.to = "console"
log.level = "trace"
log.disablePrintColor = true
`, port, tomlQuote(certPath), tomlQuote(keyPath), tomlQuote(trustedCAPath)))
		verifyE2EConfig(t, frpcPath, path)
		return path
	}

	goodConfig := clientConfig(
		"frpc-good",
		paths["client.crt"],
		paths["client.key"],
		paths["server-ca.crt"],
	)
	good := startE2EProcess(t, frpcPath, goodConfig, filepath.Join(work, "frpc-good.log"))
	waitForE2ELog(t, good, "login to server success", 12*time.Second)
	good.stop()

	badClientConfig := clientConfig(
		"frpc-untrusted-client",
		paths["rogue-client.crt"],
		paths["rogue-client.key"],
		paths["server-ca.crt"],
	)
	expectE2ERejected(t, frpcPath, badClientConfig, filepath.Join(work, "frpc-untrusted-client.log"))

	badServerConfig := clientConfig(
		"frpc-untrusted-server",
		paths["client.crt"],
		paths["client.key"],
		paths["rogue-ca.crt"],
	)
	expectE2ERejected(t, frpcPath, badServerConfig, filepath.Join(work, "frpc-untrusted-server.log"))
}

type e2eAuthority struct {
	certificatePEM []byte
	certificate    *x509.Certificate
	privateKey     crypto.Signer
}

type e2eLeaf struct {
	certificatePEM []byte
	privateKeyPEM  []byte
}

func createE2EAuthority(t *testing.T, commonName string) e2eAuthority {
	t.Helper()
	keyPEM, certificatePEM, certificate, _, err := createCA(
		commonName,
		"FRPC Android E2E",
		"ecdsa-p256",
		365,
	)
	if err != nil {
		t.Fatal(err)
	}
	key, err := parsePrivateKeyPEM(keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	clear(keyPEM)
	return e2eAuthority{
		certificatePEM: certificatePEM,
		certificate:    certificate,
		privateKey:     key,
	}
}

func createE2ELeaf(
	t *testing.T,
	commonName string,
	dnsNames []string,
	authority e2eAuthority,
	role string,
) e2eLeaf {
	t.Helper()
	keyPEM, _, csr, _, err := createCSR(
		commonName,
		"FRPC Android E2E",
		"ecdsa-p256",
		dnsNames,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	certificatePEM, _, err := issueCertificate(
		csr,
		authority.certificate,
		authority.privateKey,
		role,
		30,
	)
	if err != nil {
		t.Fatal(err)
	}
	return e2eLeaf{certificatePEM: certificatePEM, privateKeyPEM: keyPEM}
}

type e2eProcess struct {
	command *exec.Cmd
	done    chan error
	logPath string
	exited  bool
	err     error
}

func startE2EProcess(t *testing.T, binary, config, logPath string) *e2eProcess {
	t.Helper()
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(binary, "-c", config)
	command.Env = e2eProcessEnvironment()
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		t.Fatal(err)
	}
	process := &e2eProcess{
		command: command,
		done:    make(chan error, 1),
		logPath: logPath,
	}
	go func() {
		process.done <- command.Wait()
		_ = logFile.Close()
	}()
	return process
}

func (process *e2eProcess) pollExit() (bool, error) {
	if process.exited {
		return true, process.err
	}
	select {
	case process.err = <-process.done:
		process.exited = true
		return true, process.err
	default:
		return false, nil
	}
}

func (process *e2eProcess) stop() {
	if exited, _ := process.pollExit(); exited {
		return
	}
	_ = process.command.Process.Signal(os.Interrupt)
	select {
	case process.err = <-process.done:
		process.exited = true
	case <-time.After(2 * time.Second):
		_ = process.command.Process.Kill()
		process.err = <-process.done
		process.exited = true
	}
}

func reserveE2EPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

func waitForE2EPort(t *testing.T, port int, process *e2eProcess) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	for time.Now().Before(deadline) {
		if exited, err := process.pollExit(); exited {
			t.Fatalf("frps exited before listening: %v\n%s", err, readE2ELog(process.logPath))
		}
		connection, err := net.DialTimeout("tcp", address, 200*time.Millisecond)
		if err == nil {
			_ = connection.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("frps did not listen on %s\n%s", address, readE2ELog(process.logPath))
}

func waitForE2ELog(t *testing.T, process *e2eProcess, expected string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		contents := readE2ELog(process.logPath)
		if strings.Contains(contents, expected) {
			return
		}
		if exited, err := process.pollExit(); exited {
			t.Fatalf("frpc exited before %q: %v\n%s", expected, err, contents)
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("frpc did not log %q\n%s", expected, readE2ELog(process.logPath))
}

func expectE2ERejected(t *testing.T, binary, config, logPath string) {
	t.Helper()
	process := startE2EProcess(t, binary, config, logPath)
	deadline := time.Now().Add(12 * time.Second)
	for time.Now().Before(deadline) {
		if exited, err := process.pollExit(); exited {
			contents := readE2ELog(logPath)
			if err == nil {
				t.Fatalf("untrusted mTLS peer exited successfully\n%s", contents)
			}
			if strings.Contains(contents, "login to server success") {
				t.Fatalf("untrusted mTLS peer logged in\n%s", contents)
			}
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	process.stop()
	t.Fatalf("untrusted mTLS peer was not rejected\n%s", readE2ELog(logPath))
}

func verifyE2EConfig(t *testing.T, binary, config string) {
	t.Helper()
	command := exec.Command(binary, "verify", "-c", config)
	command.Env = e2eProcessEnvironment()
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("invalid generated config %s: %v\n%s", config, err, output)
	}
}

func e2eProcessEnvironment() []string {
	environment := make([]string, 0, len(os.Environ()))
	for _, entry := range os.Environ() {
		name := strings.ToLower(strings.SplitN(entry, "=", 2)[0])
		if name == "http_proxy" ||
			name == "https_proxy" ||
			name == "all_proxy" ||
			name == "no_proxy" {
			continue
		}
		environment = append(environment, entry)
	}
	return environment
}

func probeE2ETLS(t *testing.T, port int, certificatePath, keyPath, caPath string) {
	t.Helper()
	certificate, err := tls.LoadX509KeyPair(certificatePath, keyPath)
	if err != nil {
		t.Fatal(err)
	}
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		t.Fatal("could not load mTLS server CA")
	}
	dialer := &net.Dialer{Timeout: 3 * time.Second}
	connection, err := tls.DialWithDialer(
		dialer,
		"tcp",
		net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		&tls.Config{
			Certificates: []tls.Certificate{certificate},
			RootCAs:      roots,
			ServerName:   "frps.local",
			MinVersion:   tls.VersionTLS12,
		},
	)
	if err != nil {
		t.Fatalf("direct mTLS handshake failed: %v", err)
	}
	_ = connection.Close()
}

func writeE2EConfig(t *testing.T, path, contents string) {
	t.Helper()
	if err := atomicWrite(path, []byte(strings.TrimSpace(contents)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func tomlQuote(value string) string {
	return strconv.Quote(value)
}

func readE2ELog(path string) string {
	contents, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("<unable to read log: %v>", err)
	}
	return string(contents)
}
