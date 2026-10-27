package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"

	"vetka/internal/user"
)

// argon2id with OWASP's recommended minimum (19 MiB, 2 passes, 1 lane):
// ~30 ms per hash, slow enough to make offline guessing expensive, cheap
// enough not to need a queue in front of /login.
const (
	argonTime    = 2
	argonMemory  = 19 * 1024
	argonThreads = 1
	argonKeyLen  = 32
	argonSaltLen = 16

	minPassword = 8
	maxPassword = 128
)

var (
	ErrRateLimited = errors.New("auth: too many attempts")

	// Hashed for unknown usernames, so a miss costs as much as a wrong
	// password and response time does not reveal which accounts exist.
	dummyHash = mustHash("dummy password for timing")
)

func hashPassword(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, argonThreads, b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

func mustHash(password string) string {
	h, err := hashPassword(password)
	if err != nil {
		panic(err)
	}
	return h
}

// verifyPassword checks against a PHC string. The parameters come from the
// stored hash, so raising them later does not lock out existing users.
func verifyPassword(password, encoded string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false
	}
	var memory, iterations uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &iterations, &threads); err != nil {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, iterations, memory, threads, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

func validatePassword(password, username string) error {
	n := utf8.RuneCountInString(password)
	switch {
	case n < minPassword:
		return &user.ValidationError{Field: "password", Message: fmt.Sprintf("at least %d characters", minPassword)}
	case n > maxPassword:
		return &user.ValidationError{Field: "password", Message: fmt.Sprintf("at most %d characters", maxPassword)}
	case strings.EqualFold(password, username):
		return &user.ValidationError{Field: "password", Message: "must differ from the username"}
	}
	return nil
}

// Attempt limits. Per username stops guessing one account; per client
// address stops spraying one password over many accounts.
const (
	loginPerUser    = 10
	loginPerClient  = 50
	loginWindow     = 15 * time.Minute
	registerPerHour = 10
)

func (s *Service) allow(ctx context.Context, key string, limit int, window time.Duration) error {
	if s.cfg.Limiter == nil {
		return nil
	}
	ok, err := s.cfg.Limiter.Allow(ctx, key, limit, window)
	if err != nil {
		return err
	}
	if !ok {
		return ErrRateLimited
	}
	return nil
}

// Register creates an account with a username the person chose, so unlike a
// provider sign-up it needs no onboarding (IsNewUser stays false).
func (s *Service) Register(ctx context.Context, username, password, device, client string) (Session, error) {
	if err := user.ValidateUsername(username); err != nil {
		return Session{}, err
	}
	if err := validatePassword(password, username); err != nil {
		return Session{}, err
	}
	if err := s.allow(ctx, "register:client:"+client, registerPerHour, time.Hour); err != nil {
		return Session{}, err
	}
	hash, err := hashPassword(password)
	if err != nil {
		return Session{}, err
	}
	u, err := s.store.createPasswordUser(ctx, username, hash)
	if err != nil {
		return Session{}, err
	}
	s.log.InfoContext(ctx, "user signed up", slog.Int64("user_id", u.ID), slog.String("provider", "password"))
	return s.startSession(ctx, u, false, device)
}

// Login answers ErrInvalidCredentials for both an unknown username and a
// wrong password: the difference would tell an attacker which accounts exist.
func (s *Service) Login(ctx context.Context, username, password, device, client string) (Session, error) {
	if err := s.allow(ctx, "login:user:"+strings.ToLower(username), loginPerUser, loginWindow); err != nil {
		return Session{}, err
	}
	if err := s.allow(ctx, "login:client:"+client, loginPerClient, loginWindow); err != nil {
		return Session{}, err
	}

	userID, hash, err := s.store.passwordHash(ctx, username)
	if errors.Is(err, user.ErrNotFound) {
		verifyPassword(password, dummyHash)
		return Session{}, ErrInvalidCredentials
	}
	if err != nil {
		return Session{}, err
	}
	if !verifyPassword(password, hash) {
		return Session{}, ErrInvalidCredentials
	}

	u, err := s.store.userByID(ctx, userID)
	if err != nil {
		return Session{}, err
	}
	return s.startSession(ctx, u, false, device)
}
