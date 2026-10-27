package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const testBundleID = "laviosa.branch"

// fakeApple serves a JWKS and signs identity tokens like appleid.apple.com.
type fakeApple struct {
	mu       sync.Mutex
	key      *rsa.PrivateKey
	kid      string
	requests atomic.Int32
	down     atomic.Bool
	server   *httptest.Server
}

func newFakeApple(t *testing.T) *fakeApple {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeApple{key: key, kid: "test-kid"}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		f.requests.Add(1)
		if f.down.Load() {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		key, kid := f.current()
		pub := key.PublicKey
		json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
			"n": base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
		}}})
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeApple) current() (*rsa.PrivateKey, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.key, f.kid
}

func (f *fakeApple) rotate(key *rsa.PrivateKey, kid string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.key, f.kid = key, kid
}

func (f *fakeApple) verifier(now *time.Time) *AppleVerifier {
	v := NewAppleVerifier(testBundleID)
	v.keysURL = f.server.URL
	v.now = func() time.Time { return *now }
	return v
}

type appleTokenOpts struct {
	sub, aud, nonce, kid string
	exp                  time.Time
}

func (f *fakeApple) token(t *testing.T, o appleTokenOpts) string {
	t.Helper()
	sum := sha256.Sum256([]byte(o.nonce))
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, appleClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    appleIssuer,
			Subject:   o.sub,
			Audience:  jwt.ClaimStrings{o.aud},
			ExpiresAt: jwt.NewNumericDate(o.exp),
		},
		Nonce: hex.EncodeToString(sum[:]),
	})
	tok.Header["kid"] = o.kid
	key, _ := f.current()
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func (f *fakeApple) validOpts(now time.Time) appleTokenOpts {
	_, kid := f.current()
	return appleTokenOpts{sub: "001234.apple-user", aud: testBundleID, nonce: "raw-nonce", kid: kid, exp: now.Add(10 * time.Minute)}
}

func TestAppleVerify(t *testing.T) {
	f := newFakeApple(t)
	now := time.Now()
	v := f.verifier(&now)
	ctx := context.Background()

	sub, err := v.Verify(ctx, f.token(t, f.validOpts(now)), "raw-nonce")
	if err != nil || sub != "001234.apple-user" {
		t.Fatalf("Verify = %q, %v", sub, err)
	}

	bad := map[string]func(o *appleTokenOpts){
		"other audience": func(o *appleTokenOpts) { o.aud = "com.evil.app" },
		"expired":        func(o *appleTokenOpts) { o.exp = now.Add(-time.Minute) },
		"unknown kid":    func(o *appleTokenOpts) { o.kid = "nope" },
	}
	for name, mutate := range bad {
		t.Run(name, func(t *testing.T) {
			o := f.validOpts(now)
			mutate(&o)
			if _, err := v.Verify(ctx, f.token(t, o), "raw-nonce"); !errors.Is(err, ErrInvalidCredentials) {
				t.Errorf("err = %v, want ErrInvalidCredentials", err)
			}
		})
	}

	t.Run("wrong nonce", func(t *testing.T) {
		if _, err := v.Verify(ctx, f.token(t, f.validOpts(now)), "other-nonce"); !errors.Is(err, ErrInvalidCredentials) {
			t.Errorf("err = %v, want ErrInvalidCredentials", err)
		}
	})
	t.Run("missing nonce", func(t *testing.T) {
		if _, err := v.Verify(ctx, f.token(t, f.validOpts(now)), ""); !errors.Is(err, ErrInvalidCredentials) {
			t.Errorf("err = %v, want ErrInvalidCredentials", err)
		}
	})
}

func TestAppleKeyCache(t *testing.T) {
	f := newFakeApple(t)
	now := time.Now()
	v := f.verifier(&now)
	ctx := context.Background()

	for range 3 {
		if _, err := v.Verify(ctx, f.token(t, f.validOpts(now)), "raw-nonce"); err != nil {
			t.Fatal(err)
		}
	}
	if n := f.requests.Load(); n != 1 {
		t.Errorf("keys fetched %d times for 3 verifications, want 1", n)
	}

	// Forged kids right after a fetch must not hit Apple again.
	o := f.validOpts(now)
	o.kid = "forged"
	v.Verify(ctx, f.token(t, o), "raw-nonce")
	if n := f.requests.Load(); n != 1 {
		t.Errorf("unknown kid refetched within a minute: %d requests", n)
	}

	// Apple rotated keys: a new kid after the refetch interval is picked up.
	now = now.Add(2 * time.Minute)
	newKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	f.rotate(newKey, "rotated-kid")
	if _, err := v.Verify(ctx, f.token(t, f.validOpts(now)), "raw-nonce"); err != nil {
		t.Errorf("rotated key: %v", err)
	}
}

func TestAppleKeysUnavailable(t *testing.T) {
	f := newFakeApple(t)
	f.down.Store(true)
	now := time.Now()
	v := f.verifier(&now)

	_, err := v.Verify(context.Background(), f.token(t, f.validOpts(now)), "raw-nonce")
	if !errors.Is(err, ErrProviderUnavailable) {
		t.Errorf("err = %v, want ErrProviderUnavailable", err)
	}
}

func TestAppleServesStaleKeysWhileAppleIsDown(t *testing.T) {
	f := newFakeApple(t)
	now := time.Now()
	v := f.verifier(&now)
	ctx := context.Background()
	if _, err := v.Verify(ctx, f.token(t, f.validOpts(now)), "raw-nonce"); err != nil {
		t.Fatal(err)
	}

	f.down.Store(true)
	now = now.Add(25 * time.Hour) // cache is stale, refetch fails
	if _, err := v.Verify(ctx, f.token(t, f.validOpts(now)), "raw-nonce"); err != nil {
		t.Errorf("stale cached key must still work while Apple is down: %v", err)
	}
}
