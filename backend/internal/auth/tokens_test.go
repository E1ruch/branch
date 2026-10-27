package auth

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func newTestIssuer(t *testing.T, now *time.Time) *Issuer {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	i := NewIssuer(key, 15*time.Minute)
	i.now = func() time.Time { return *now }
	return i
}

func TestAccessTokenRoundTrip(t *testing.T) {
	now := time.Now()
	i := newTestIssuer(t, &now)

	token, exp, err := i.Issue(42)
	if err != nil {
		t.Fatal(err)
	}
	if want := now.Add(15 * time.Minute); !exp.Equal(want) {
		t.Errorf("expiry = %v, want %v", exp, want)
	}
	id, err := i.Verify(token)
	if err != nil || id != 42 {
		t.Fatalf("Verify = %d, %v; want 42, nil", id, err)
	}

	now = now.Add(16 * time.Minute)
	if _, err := i.Verify(token); !errors.Is(err, ErrTokenExpired) {
		t.Errorf("after TTL: err = %v, want ErrTokenExpired", err)
	}
}

func TestAccessTokenRejectsForeignAndTampered(t *testing.T) {
	now := time.Now()
	ours, theirs := newTestIssuer(t, &now), newTestIssuer(t, &now)

	foreign, _, _ := theirs.Issue(42)
	if _, err := ours.Verify(foreign); !errors.Is(err, ErrTokenInvalid) {
		t.Errorf("foreign key: err = %v, want ErrTokenInvalid", err)
	}

	// Flip a bit of the signature itself: editing base64 text can land in
	// padding bits and leave the decoded signature unchanged.
	token, _, _ := ours.Issue(42)
	dot := strings.LastIndexByte(token, '.')
	sig, err := base64.RawURLEncoding.DecodeString(token[dot+1:])
	if err != nil {
		t.Fatal(err)
	}
	sig[0] ^= 1
	tampered := token[:dot+1] + base64.RawURLEncoding.EncodeToString(sig)
	if _, err := ours.Verify(tampered); !errors.Is(err, ErrTokenInvalid) {
		t.Errorf("tampered: err = %v, want ErrTokenInvalid", err)
	}

	if _, err := ours.Verify("not-a-jwt"); !errors.Is(err, ErrTokenInvalid) {
		t.Errorf("garbage: err = %v, want ErrTokenInvalid", err)
	}
}

func TestRefreshTokensAreUniqueAndHashed(t *testing.T) {
	a, hashA := newRefreshToken()
	b, _ := newRefreshToken()
	if a == b {
		t.Fatal("two refresh tokens are equal")
	}
	if string(hashA) == a || len(hashA) != 32 {
		t.Errorf("hash must be a 32-byte SHA-256, got %d bytes", len(hashA))
	}
	if string(hashRefreshToken(a)) != string(hashA) {
		t.Error("hash is not deterministic")
	}
}
