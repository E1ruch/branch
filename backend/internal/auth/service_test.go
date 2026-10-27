package auth

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"vetka/internal/testdb"
)

type memReplay struct {
	mu   sync.Mutex
	seen map[string]bool
}

func (m *memReplay) Claim(_ context.Context, key string, _ time.Duration) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.seen[key] {
		return false, nil
	}
	m.seen[key] = true
	return true, nil
}

const testRefreshTTL = 60 * 24 * time.Hour

type testEnv struct {
	svc   *Service
	now   *time.Time
	apple *fakeApple
}

func newTestEnv(t *testing.T) testEnv {
	t.Helper()
	db := testdb.New(t)
	now := new(time.Time)
	*now = time.Now().Truncate(time.Second)
	apple := newFakeApple(t)

	svc := NewService(db, newTestIssuer(t, now), apple.verifier(now), &memReplay{seen: map[string]bool{}},
		Config{
			RefreshTTL:       testRefreshTTL,
			RefreshGrace:     30 * time.Second,
			TelegramBotToken: testBotToken,
			TelegramMaxAge:   time.Hour,
		},
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	svc.now = func() time.Time { return *now }
	return testEnv{svc: svc, now: now, apple: apple}
}

func (e testEnv) telegram(t *testing.T, id int64, username string) Session {
	t.Helper()
	*e.now = e.now.Add(time.Second) // fresh auth_date, fresh hash
	s, err := e.svc.SignInWithTelegram(context.Background(), telegramData(id, username, *e.now), "iPhone")
	if err != nil {
		t.Fatalf("telegram sign-in: %v", err)
	}
	return s
}

func TestTelegramSignUpThenSignIn(t *testing.T) {
	e := newTestEnv(t)

	first := e.telegram(t, 42, "ivan_tg")
	if !first.IsNewUser || first.User.Username != "ivan_tg" {
		t.Fatalf("first sign-in: new=%v username=%q", first.IsNewUser, first.User.Username)
	}
	if first.User.DisplayName == nil || *first.User.DisplayName != "Иван" {
		t.Errorf("display name = %v, want Иван", first.User.DisplayName)
	}

	second := e.telegram(t, 42, "ivan_tg")
	if second.IsNewUser || second.User.ID != first.User.ID {
		t.Errorf("second sign-in: new=%v id=%d, want existing user %d", second.IsNewUser, second.User.ID, first.User.ID)
	}
}

func TestTakenUsernameFallsBackToGenerated(t *testing.T) {
	e := newTestEnv(t)
	e.telegram(t, 1, "popular")

	other := e.telegram(t, 2, "POPULAR") // usernames are case-insensitive
	if !strings.HasPrefix(other.User.Username, "user_") {
		t.Errorf("username = %q, want a generated user_*", other.User.Username)
	}
}

func TestTelegramReplayRejected(t *testing.T) {
	e := newTestEnv(t)
	data := telegramData(42, "ivan", *e.now)
	ctx := context.Background()

	if _, err := e.svc.SignInWithTelegram(ctx, data, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.SignInWithTelegram(ctx, data, ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("replayed data: err = %v, want ErrInvalidCredentials", err)
	}
}

func TestAppleSignUpThenSignIn(t *testing.T) {
	e := newTestEnv(t)
	ctx := context.Background()
	token := e.apple.token(t, e.apple.validOpts(*e.now))

	first, err := e.svc.SignInWithApple(ctx, AppleSignIn{IdentityToken: token, Nonce: "raw-nonce", GivenName: "Иван", FamilyName: "Петров"})
	if err != nil {
		t.Fatal(err)
	}
	if !first.IsNewUser || first.User.DisplayName == nil || *first.User.DisplayName != "Иван Петров" {
		t.Errorf("first: new=%v name=%v", first.IsNewUser, first.User.DisplayName)
	}

	// Apple omits the name on later sign-ins; the stored one must survive.
	second, err := e.svc.SignInWithApple(ctx, AppleSignIn{IdentityToken: token, Nonce: "raw-nonce"})
	if err != nil {
		t.Fatal(err)
	}
	if second.IsNewUser || second.User.ID != first.User.ID || *second.User.DisplayName != "Иван Петров" {
		t.Errorf("second: new=%v id=%d name=%v", second.IsNewUser, second.User.ID, second.User.DisplayName)
	}
}

func TestRefreshRotationAndReuseDetection(t *testing.T) {
	e := newTestEnv(t)
	ctx := context.Background()
	r0 := e.telegram(t, 42, "ivan").RefreshToken

	t1, err := e.svc.Refresh(ctx, r0)
	if err != nil {
		t.Fatal(err)
	}
	id, err := e.svc.VerifyAccessToken(t1.AccessToken)
	if err != nil || id == 0 {
		t.Fatalf("refreshed access token: %d, %v", id, err)
	}

	// Lost response: the client retries r0 within the grace window.
	if _, err := e.svc.Refresh(ctx, r0); err != nil {
		t.Fatalf("retry within grace: %v", err)
	}

	t2, err := e.svc.Refresh(ctx, t1.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}

	// Long after rotation r1 shows up again: it leaked. The family dies.
	*e.now = e.now.Add(time.Minute)
	if _, err := e.svc.Refresh(ctx, t1.RefreshToken); !errors.Is(err, ErrRefreshReused) {
		t.Fatalf("reuse: err = %v, want ErrRefreshReused", err)
	}
	if _, err := e.svc.Refresh(ctx, t2.RefreshToken); !errors.Is(err, ErrRefreshInvalid) {
		t.Errorf("newest token after reuse: err = %v, want ErrRefreshInvalid", err)
	}
}

func TestRefreshExpires(t *testing.T) {
	e := newTestEnv(t)
	r := e.telegram(t, 42, "ivan").RefreshToken

	*e.now = e.now.Add(testRefreshTTL + time.Second)
	if _, err := e.svc.Refresh(context.Background(), r); !errors.Is(err, ErrRefreshInvalid) {
		t.Errorf("err = %v, want ErrRefreshInvalid", err)
	}
}

func TestLogoutEndsOnlyThatDevice(t *testing.T) {
	e := newTestEnv(t)
	ctx := context.Background()
	phone := e.telegram(t, 42, "ivan").RefreshToken
	tablet := e.telegram(t, 42, "ivan").RefreshToken

	rotated, err := e.svc.Refresh(ctx, phone)
	if err != nil {
		t.Fatal(err)
	}
	// Logging out with an older token of the family still ends the session.
	if err := e.svc.Logout(ctx, phone); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Refresh(ctx, rotated.RefreshToken); !errors.Is(err, ErrRefreshInvalid) {
		t.Errorf("after logout: err = %v, want ErrRefreshInvalid", err)
	}
	if _, err := e.svc.Refresh(ctx, tablet); err != nil {
		t.Errorf("other device must stay signed in: %v", err)
	}

	if err := e.svc.Logout(ctx, phone); err != nil {
		t.Errorf("repeated logout: %v", err)
	}
	if err := e.svc.Logout(ctx, "unknown"); err != nil {
		t.Errorf("unknown token logout: %v", err)
	}
}
