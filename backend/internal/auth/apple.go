package auth

import (
	"context"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	appleIssuer  = "https://appleid.apple.com"
	appleKeysURL = "https://appleid.apple.com/auth/keys"

	appleKeysMaxAge = 24 * time.Hour
	// An unknown kid triggers a refetch, but not more often than this:
	// otherwise forged tokens with random kids would hammer Apple through us.
	appleMinRefetch = time.Minute
)

// AppleVerifier checks Sign in with Apple identity tokens against Apple's
// published keys, cached in memory.
type AppleVerifier struct {
	clientID string // the app bundle ID, the token's audience
	keysURL  string
	client   *http.Client
	now      func() time.Time

	mu        sync.Mutex
	keys      map[string]*rsa.PublicKey
	fetchedAt time.Time
}

func NewAppleVerifier(bundleID string) *AppleVerifier {
	return &AppleVerifier{
		clientID: bundleID,
		keysURL:  appleKeysURL,
		client:   &http.Client{Timeout: 5 * time.Second},
		now:      time.Now,
	}
}

type appleClaims struct {
	jwt.RegisteredClaims
	Nonce string `json:"nonce"`
}

// Verify returns the stable Apple user ID (`sub`).
//
// rawNonce is the random string the app generated; the app passed its SHA-256
// hex to Apple, which embedded it in the token. Checking it binds the token to
// this sign-in attempt, so a token intercepted elsewhere cannot be replayed.
func (v *AppleVerifier) Verify(ctx context.Context, identityToken, rawNonce string) (string, error) {
	if rawNonce == "" {
		return "", fmt.Errorf("%w: missing nonce", ErrInvalidCredentials)
	}

	var keyErr error
	var claims appleClaims
	_, err := jwt.ParseWithClaims(identityToken, &claims,
		func(t *jwt.Token) (any, error) {
			kid, _ := t.Header["kid"].(string)
			key, err := v.key(ctx, kid)
			keyErr = err
			return key, err
		},
		jwt.WithValidMethods([]string{jwt.SigningMethodRS256.Alg()}),
		jwt.WithIssuer(appleIssuer),
		jwt.WithAudience(v.clientID),
		jwt.WithExpirationRequired(),
		jwt.WithTimeFunc(v.now),
	)
	if errors.Is(keyErr, ErrProviderUnavailable) {
		return "", keyErr
	}
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidCredentials, err)
	}

	sum := sha256.Sum256([]byte(rawNonce))
	if subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(claims.Nonce)) != 1 {
		return "", fmt.Errorf("%w: nonce mismatch", ErrInvalidCredentials)
	}
	if claims.Subject == "" {
		return "", fmt.Errorf("%w: empty subject", ErrInvalidCredentials)
	}
	return claims.Subject, nil
}

func (v *AppleVerifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()

	now := v.now()
	key, ok := v.keys[kid]
	stale := now.Sub(v.fetchedAt) > appleKeysMaxAge
	if ok && !stale {
		return key, nil
	}
	if !stale && now.Sub(v.fetchedAt) < appleMinRefetch {
		return nil, fmt.Errorf("unknown key id %q", kid)
	}

	keys, err := v.fetchKeys(ctx)
	if err != nil {
		if ok {
			return key, nil // Apple is down, but the cached key is still good
		}
		return nil, fmt.Errorf("%w: apple keys: %v", ErrProviderUnavailable, err)
	}
	v.keys, v.fetchedAt = keys, now

	if key, ok = keys[kid]; !ok {
		return nil, fmt.Errorf("unknown key id %q", kid)
	}
	return key, nil
}

func (v *AppleVerifier) fetchKeys(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.keysURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}

	var set struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return nil, err
	}

	keys := make(map[string]*rsa.PublicKey, len(set.Keys))
	for _, k := range set.Keys {
		if k.Kty != "RSA" {
			continue
		}
		n, errN := base64.RawURLEncoding.DecodeString(k.N)
		e, errE := base64.RawURLEncoding.DecodeString(k.E)
		if errN != nil || errE != nil {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	if len(keys) == 0 {
		return nil, errors.New("no usable keys")
	}
	return keys, nil
}
