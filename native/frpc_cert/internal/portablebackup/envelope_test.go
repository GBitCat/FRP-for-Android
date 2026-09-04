package portablebackup

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"hash"
	"strings"
	"testing"
)

const crossImplementationPassword = "备份密码🔐portable"

var crossImplementationVectors = []struct {
	kdf     byte
	encoded string
}{
	{
		kdf: KDFPBKDF2SHA256,
		encoded: "RlJQQgEBAAGGoBAMMDEyMzQ1Njc4OWFiY2RlZmFiY2RlZmdoaWprbIoZ+Wwmla8A7f1r" +
			"abOqIPmvYUGj5sWvvpN3Bh2pHS9L0GibksGlpQCDsZGa0zMjXobiizAfCd8r",
	},
	{
		kdf: KDFPBKDF2SHA1,
		encoded: "RlJQQgECAAGGoBAMMDEyMzQ1Njc4OWFiY2RlZmFiY2RlZmdoaWprbOgJzfRPHZWAu7BJ" +
			"pHlSEUghVoWWNh83Sz2JZW9g581gZP74VKJVRGao2oAEtrbJkfQ9KLeJnNZ6",
	},
}

// These vectors are copied verbatim into BackupCipherCompatibilityTest.kt.
// They fix UTF-8 password bytes, header byte order, AAD, and both supported
// PBKDF2 digests independently of either implementation's random generator.
func TestDecryptCrossImplementationNonASCIIKnownVectors(t *testing.T) {
	t.Parallel()
	want := "FRPB cross-language vector: 设备证书"
	for _, vector := range crossImplementationVectors {
		vector := vector
		t.Run(string(rune('0'+vector.kdf)), func(t *testing.T) {
			t.Parallel()
			envelope, err := base64.StdEncoding.DecodeString(vector.encoded)
			if err != nil {
				t.Fatal(err)
			}
			if envelope[5] != vector.kdf {
				t.Fatalf("KDF marker = %d, want %d", envelope[5], vector.kdf)
			}
			got, err := Decrypt(envelope, crossImplementationPassword)
			if err != nil {
				t.Fatal(err)
			}
			defer clear(got)
			if string(got) != want {
				t.Fatalf("plaintext = %q, want %q", got, want)
			}
		})
	}
}

func TestDecryptCompatibleEnvelopes(t *testing.T) {
	t.Parallel()
	for _, kdf := range []byte{KDFPBKDF2SHA256, KDFPBKDF2SHA1} {
		kdf := kdf
		t.Run(string(rune('0'+kdf)), func(t *testing.T) {
			t.Parallel()
			plaintext := []byte("zip bytes including a private key")
			envelope := testEncrypt(t, plaintext, "portable passphrase", kdf)
			got, err := Decrypt(envelope, "portable passphrase")
			if err != nil {
				t.Fatal(err)
			}
			defer clear(got)
			if string(got) != string(plaintext) {
				t.Fatalf("plaintext = %q, want %q", got, plaintext)
			}
		})
	}
}

func TestDecryptRejectsWrongPasswordAndTampering(t *testing.T) {
	t.Parallel()
	envelope := testEncrypt(t, []byte("secret"), "correct password", KDFPBKDF2SHA256)

	if _, err := Decrypt(envelope, "wrong password"); !errors.Is(err, ErrInvalidEnvelope) {
		t.Fatalf("wrong password error = %v, want ErrInvalidEnvelope", err)
	}
	envelope[len(envelope)-1] ^= 0x01
	if _, err := Decrypt(envelope, "correct password"); !errors.Is(err, ErrInvalidEnvelope) {
		t.Fatalf("tampering error = %v, want ErrInvalidEnvelope", err)
	}
}

func TestDecryptRejectsPasswordOutsideResourceBounds(t *testing.T) {
	t.Parallel()
	envelope := testEncrypt(t, []byte("secret"), "correct password", KDFPBKDF2SHA256)
	for _, password := range []string{
		"short",
		strings.Repeat("x", MaxPasswordBytes+1),
	} {
		if _, err := Decrypt(envelope, password); !errors.Is(err, ErrInvalidEnvelope) {
			t.Fatalf("password length %d error = %v, want ErrInvalidEnvelope", len(password), err)
		}
	}
}

func TestDecryptRejectsUnsafeParameters(t *testing.T) {
	t.Parallel()
	valid := testEncrypt(t, []byte("secret"), "correct password", KDFPBKDF2SHA256)
	tests := map[string]func([]byte){
		"magic":      func(b []byte) { b[0] = 'X' },
		"version":    func(b []byte) { b[4] = 2 },
		"kdf":        func(b []byte) { b[5] = 99 },
		"iterations": func(b []byte) { binary.BigEndian.PutUint32(b[6:10], 1) },
		"salt size":  func(b []byte) { b[10] = 1 },
		"nonce size": func(b []byte) { b[11] = 1 },
	}
	for name, mutate := range tests {
		name, mutate := name, mutate
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			candidate := append([]byte(nil), valid...)
			mutate(candidate)
			if _, err := Decrypt(candidate, "correct password"); !errors.Is(err, ErrInvalidEnvelope) {
				t.Fatalf("error = %v, want ErrInvalidEnvelope", err)
			}
		})
	}
}

func TestDecryptEnforcesPlaintextAndEnvelopeBoundaries(t *testing.T) {
	t.Parallel()
	if MaxEnvelopeBytes != MaxPlaintextBytes+128 {
		t.Fatalf("envelope allowance = %d, want 128", MaxEnvelopeBytes-MaxPlaintextBytes)
	}
	if plaintext, err := Decrypt(
		testEncrypt(t, nil, "correct password", KDFPBKDF2SHA256),
		"correct password",
	); !errors.Is(err, ErrInvalidEnvelope) || plaintext != nil {
		t.Fatalf("empty plaintext returned %d bytes, error=%v", len(plaintext), err)
	}

	boundary := make([]byte, MaxPlaintextBytes)
	boundaryEnvelope := testEncrypt(t, boundary, "correct password", KDFPBKDF2SHA256)
	clear(boundary)
	plaintext, err := Decrypt(boundaryEnvelope, "correct password")
	if err != nil || len(plaintext) != MaxPlaintextBytes {
		t.Fatalf("boundary plaintext returned %d bytes, error=%v", len(plaintext), err)
	}
	clear(plaintext)

	oversized := make([]byte, MaxPlaintextBytes+1)
	envelope := testEncrypt(t, oversized, "correct password", KDFPBKDF2SHA256)
	clear(oversized)
	if plaintext, err := Decrypt(envelope, "correct password"); !errors.Is(err, ErrInvalidEnvelope) || plaintext != nil {
		t.Fatalf("oversized plaintext returned %d bytes, error=%v", len(plaintext), err)
	}
}

func testEncrypt(t *testing.T, plaintext []byte, password string, kdf byte) []byte {
	t.Helper()
	const iterations = 600_000
	salt := []byte("0123456789abcdef")
	nonce := []byte("abcdefghijkl")
	header := make([]byte, fixedHeaderBytes+len(salt)+len(nonce))
	copy(header, magic[:])
	header[4] = Version
	header[5] = kdf
	binary.BigEndian.PutUint32(header[6:10], iterations)
	header[10] = byte(len(salt))
	header[11] = byte(len(nonce))
	copy(header[fixedHeaderBytes:], salt)
	copy(header[fixedHeaderBytes+len(salt):], nonce)

	var digest func() hash.Hash
	if kdf == KDFPBKDF2SHA1 {
		digest = sha1.New
	} else {
		digest = sha256.New
	}
	key, err := pbkdf2.Key(digest, password, salt, iterations, 32)
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
