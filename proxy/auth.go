package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/crypto/argon2"
)

// Argon2id parameters. memory in KiB, time = passes, threads = parallelism.
// Tuned for a personal-use macOS app: ~64 MiB memory, ~0.1s on Apple silicon.
const (
	argonMemory  uint32 = 64 * 1024
	argonTime    uint32 = 2
	argonThreads uint8  = 2
	argonKeyLen  uint32 = 32
	argonSaltLen        = 16
)

// SecretsFile holds the encoded password hash. We store a single self-
// describing string so future parameter changes don't break verification
// of pre-existing hashes.
type SecretsFile struct {
	Hash string `json:"hash,omitempty"`
}

// Auth wraps password storage + verification. Concurrency-safe.
type Auth struct {
	mu          sync.Mutex
	secretsPath string
	hash        string
}

func NewAuth(secretsPath string) (*Auth, error) {
	a := &Auth{secretsPath: secretsPath}
	if err := a.load(); err != nil {
		return nil, err
	}
	return a, nil
}

func (a *Auth) load() error {
	data, err := os.ReadFile(a.secretsPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read secrets: %w", err)
	}
	var sf SecretsFile
	if err := json.Unmarshal(data, &sf); err != nil {
		return fmt.Errorf("parse secrets: %w", err)
	}
	a.hash = sf.Hash
	return nil
}

func (a *Auth) save() error {
	sf := SecretsFile{Hash: a.hash}
	data, err := json.MarshalIndent(sf, "", "  ")
	if err != nil {
		return err
	}
	tmp := a.secretsPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.secretsPath)
}

// IsSet reports whether a password is currently configured.
func (a *Auth) IsSet() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.hash != ""
}

// Verify is a constant-time check of password against the stored hash.
// Returns false (no error) if no password is set or password is wrong.
func (a *Auth) Verify(password string) bool {
	a.mu.Lock()
	hash := a.hash
	a.mu.Unlock()
	if hash == "" || password == "" {
		return false
	}
	expected, err := decodeArgon2(hash)
	if err != nil {
		return false
	}
	computed := argon2.IDKey(
		[]byte(password), expected.salt,
		expected.time, expected.memory, expected.threads, expected.keyLen,
	)
	return subtle.ConstantTimeCompare(computed, expected.hash) == 1
}

// Set replaces the stored password. If a password is already set, currentPwd
// must match; otherwise pass "". newPwd must be non-empty.
func (a *Auth) Set(currentPwd, newPwd string) error {
	if newPwd == "" {
		return errors.New("new password is empty")
	}
	a.mu.Lock()
	hasExisting := a.hash != ""
	a.mu.Unlock()

	if hasExisting && !a.Verify(currentPwd) {
		return errors.New("current password is incorrect")
	}

	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	key := argon2.IDKey([]byte(newPwd), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	encoded := encodeArgon2(argon2Params{
		time:    argonTime,
		memory:  argonMemory,
		threads: argonThreads,
		keyLen:  argonKeyLen,
		salt:    salt,
		hash:    key,
	})

	a.mu.Lock()
	a.hash = encoded
	a.mu.Unlock()
	return a.save()
}

// Clear removes the stored password. Requires the current one (so a stray
// IPC client can't disarm the lock).
func (a *Auth) Clear(currentPwd string) error {
	if !a.Verify(currentPwd) {
		return errors.New("current password is incorrect")
	}
	a.mu.Lock()
	a.hash = ""
	a.mu.Unlock()
	return a.save()
}

// ResetEverything wipes the password without requiring the old one. Used
// by the "Reset everything" recovery path so a forgotten password isn't
// a permanent lock-out. Intentionally not exposed over IPC — only the
// app's About-tab reset flow should call this.
func (a *Auth) ResetEverything() error {
	a.mu.Lock()
	a.hash = ""
	a.mu.Unlock()
	if _, err := os.Stat(a.secretsPath); err == nil {
		return os.Remove(a.secretsPath)
	}
	return nil
}

// MARK: - Argon2 encoding (PHC string format)
// $argon2id$v=19$m=...,t=...,p=...$<salt>$<hash>

type argon2Params struct {
	time, memory uint32
	threads      uint8
	keyLen       uint32
	salt, hash   []byte
}

func encodeArgon2(p argon2Params) string {
	saltB64 := base64.RawStdEncoding.EncodeToString(p.salt)
	hashB64 := base64.RawStdEncoding.EncodeToString(p.hash)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, p.memory, p.time, p.threads, saltB64, hashB64)
}

func decodeArgon2(s string) (argon2Params, error) {
	var p argon2Params
	parts := strings.Split(s, "$")
	// ["", "argon2id", "v=19", "m=...,t=...,p=...", "salt", "hash"]
	if len(parts) != 6 || parts[1] != "argon2id" {
		return p, errors.New("not an argon2id hash")
	}
	// v=19
	if !strings.HasPrefix(parts[2], "v=") {
		return p, errors.New("bad version segment")
	}
	if v, err := strconv.Atoi(parts[2][2:]); err != nil || uint32(v) != argon2.Version {
		return p, errors.New("unsupported argon2 version")
	}
	// m=...,t=...,p=...
	for _, kv := range strings.Split(parts[3], ",") {
		bits := strings.SplitN(kv, "=", 2)
		if len(bits) != 2 {
			return p, errors.New("bad params")
		}
		n, err := strconv.Atoi(bits[1])
		if err != nil {
			return p, errors.New("bad param value")
		}
		switch bits[0] {
		case "m":
			p.memory = uint32(n)
		case "t":
			p.time = uint32(n)
		case "p":
			p.threads = uint8(n)
		}
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return p, fmt.Errorf("bad salt: %w", err)
	}
	hash, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return p, fmt.Errorf("bad hash: %w", err)
	}
	p.salt = salt
	p.hash = hash
	p.keyLen = uint32(len(hash))
	return p, nil
}
