package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const tokenIssuer = "vetka"

var (
	// ErrTokenExpired tells the client to refresh; any other access token
	// error means the session is unusable.
	ErrTokenExpired = errors.New("auth: access token expired")
	ErrTokenInvalid = errors.New("auth: access token invalid")
)

// Issuer signs and verifies access tokens: short-lived JWTs checked without a
// database lookup. Ed25519 rather than HMAC so other services (a separate
// WebSocket gateway, say) can verify tokens holding only the public key.
type Issuer struct {
	key ed25519.PrivateKey
	pub ed25519.PublicKey
	ttl time.Duration
	now func() time.Time
}

func NewIssuer(key ed25519.PrivateKey, ttl time.Duration) *Issuer {
	return &Issuer{key: key, pub: key.Public().(ed25519.PublicKey), ttl: ttl, now: time.Now}
}

func (i *Issuer) Issue(userID int64) (string, time.Time, error) {
	now := i.now()
	exp := now.Add(i.ttl)
	claims := jwt.RegisteredClaims{
		Issuer:    tokenIssuer,
		Subject:   strconv.FormatInt(userID, 10),
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(exp),
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodEdDSA, claims).SignedString(i.key)
	return token, exp, err
}

func (i *Issuer) Verify(token string) (int64, error) {
	var claims jwt.RegisteredClaims
	_, err := jwt.ParseWithClaims(token, &claims,
		func(*jwt.Token) (any, error) { return i.pub, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodEdDSA.Alg()}),
		jwt.WithIssuer(tokenIssuer),
		jwt.WithExpirationRequired(),
		jwt.WithTimeFunc(i.now),
	)
	if errors.Is(err, jwt.ErrTokenExpired) {
		return 0, ErrTokenExpired
	}
	if err != nil {
		return 0, ErrTokenInvalid
	}
	id, err := strconv.ParseInt(claims.Subject, 10, 64)
	if err != nil || id <= 0 {
		return 0, ErrTokenInvalid
	}
	return id, nil
}

// newRefreshToken returns an opaque 128-bit token and the hash stored in the
// database. A leaked database dump does not yield usable tokens.
func newRefreshToken() (raw string, hash []byte) {
	raw = rand.Text()
	return raw, hashRefreshToken(raw)
}

func hashRefreshToken(raw string) []byte {
	sum := sha256.Sum256([]byte(raw))
	return sum[:]
}
