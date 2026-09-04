// Package portablebackup decodes the password-protected envelope used by
// Android certificate exports. It intentionally contains no certificate or
// filesystem policy; callers must validate and safely persist the plaintext.
package portablebackup

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha1" // #nosec G505 -- required only for backwards-compatible PBKDF2 envelopes.
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
)

const (
	Version = 1

	KDFPBKDF2SHA256 = 1
	KDFPBKDF2SHA1   = 2

	MinIterations = 100_000
	MaxIterations = 1_000_000

	MaxPlaintextBytes = 5 * 1024 * 1024
	// Android and Dart reserve 128 bytes for the authenticated envelope.
	// FRPB v1 currently uses 56 bytes with the production salt and nonce.
	MaxEnvelopeBytes = MaxPlaintextBytes + 128
	MinPasswordBytes = 12
	MaxPasswordBytes = 4096

	fixedHeaderBytes = 12
	gcmTagBytes      = 16
)

var (
	magic = [4]byte{'F', 'R', 'P', 'B'}

	// ErrInvalidEnvelope deliberately covers malformed data, unsupported
	// parameters, and authentication failures so callers do not expose an
	// oracle that distinguishes wrong passwords from damaged exports.
	ErrInvalidEnvelope = errors.New("invalid bundle or password")
)

// Decrypt verifies and decrypts one FRPB v1 envelope. The returned byte slice
// is owned by the caller and should be cleared after use because it can contain
// private keys.
func Decrypt(envelope []byte, password string) ([]byte, error) {
	if len(password) < MinPasswordBytes || len(password) > MaxPasswordBytes {
		return nil, ErrInvalidEnvelope
	}
	if len(envelope) < fixedHeaderBytes+16+12+gcmTagBytes || len(envelope) > MaxEnvelopeBytes {
		return nil, ErrInvalidEnvelope
	}
	if subtle.ConstantTimeCompare(envelope[:len(magic)], magic[:]) != 1 || envelope[4] != Version {
		return nil, ErrInvalidEnvelope
	}

	iterations := int(binary.BigEndian.Uint32(envelope[6:10]))
	saltBytes := int(envelope[10])
	nonceBytes := int(envelope[11])
	if iterations < MinIterations || iterations > MaxIterations ||
		saltBytes < 16 || saltBytes > 32 || nonceBytes < 12 || nonceBytes > 16 {
		return nil, ErrInvalidEnvelope
	}
	headerBytes := fixedHeaderBytes + saltBytes + nonceBytes
	if headerBytes > len(envelope)-gcmTagBytes {
		return nil, ErrInvalidEnvelope
	}

	var digest func() hash.Hash
	switch envelope[5] {
	case KDFPBKDF2SHA256:
		digest = sha256.New
	case KDFPBKDF2SHA1:
		digest = sha1.New
	default:
		return nil, ErrInvalidEnvelope
	}

	key, err := pbkdf2.Key(
		digest,
		password,
		envelope[fixedHeaderBytes:fixedHeaderBytes+saltBytes],
		iterations,
		32,
	)
	if err != nil {
		return nil, fmt.Errorf("derive bundle key: %w", ErrInvalidEnvelope)
	}
	defer clear(key)

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("initialize bundle cipher: %w", ErrInvalidEnvelope)
	}
	aead, err := cipher.NewGCMWithNonceSize(block, nonceBytes)
	if err != nil {
		return nil, fmt.Errorf("initialize bundle authentication: %w", ErrInvalidEnvelope)
	}
	nonceStart := fixedHeaderBytes + saltBytes
	plaintext, err := aead.Open(
		nil,
		envelope[nonceStart:headerBytes],
		envelope[headerBytes:],
		envelope[:headerBytes],
	)
	if err != nil || len(plaintext) == 0 || len(plaintext) > MaxPlaintextBytes {
		clear(plaintext)
		return nil, ErrInvalidEnvelope
	}
	return plaintext, nil
}
