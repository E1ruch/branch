package auth

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"vetka/internal/user"
)

func TestPasswordHashing(t *testing.T) {
	h, err := hashPassword("correct horse")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$m=19456,t=2,p=1$") {
		t.Errorf("not a PHC argon2id string: %s", h)
	}
	if !verifyPassword("correct horse", h) {
		t.Error("right password rejected")
	}
	if verifyPassword("correct horsE", h) {
		t.Error("wrong password accepted")
	}
	h2, _ := hashPassword("correct horse")
	if h == h2 {
		t.Error("same password must get a different salt")
	}
	for _, bad := range []string{"", "plaintext", "$argon2i$v=19$m=1,t=1,p=1$AA$AA", "$argon2id$v=19$garbage$AA$AA"} {
		if verifyPassword("x", bad) {
			t.Errorf("malformed hash %q accepted", bad)
		}
	}
}

func TestPasswordRules(t *testing.T) {
	var verr *user.ValidationError
	for _, tt := range []struct{ password, username string }{
		{"short", "ivan"},
		{strings.Repeat("я", maxPassword+1), "ivan"},
		{"IvanIvan", "ivanivan"},
	} {
		if err := validatePassword(tt.password, tt.username); !errors.As(err, &verr) || verr.Field != "password" {
			t.Errorf("%q for %q: %v", tt.password, tt.username, err)
		}
	}
	if err := validatePassword("пароль-на-русском", "ivan"); err != nil {
		t.Errorf("valid password rejected: %v", err)
	}
}

type countingLimiter struct {
	mu     sync.Mutex
	counts map[string]int
}

func (l *countingLimiter) Allow(_ context.Context, key string, limit int, _ time.Duration) (bool, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.counts[key]++
	return l.counts[key] <= limit, nil
}

func TestRegisterAndLogin(t *testing.T) {
	e := newTestEnv(t)
	ctx := context.Background()

	s, err := e.svc.Register(ctx, "Ivan_P", "secret-pass", "iPhone", "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if s.User.Username != "Ivan_P" || s.IsNewUser || s.AccessToken == "" || s.RefreshToken == "" {
		t.Errorf("register: %+v", s)
	}

	if _, err := e.svc.Register(ctx, "ivan_p", "other-pass", "", "10.0.0.2"); !errors.Is(err, user.ErrUsernameTaken) {
		t.Errorf("taken (case-insensitive): %v", err)
	}
	var verr *user.ValidationError
	if _, err := e.svc.Register(ctx, "admin", "secret-pass", "", "10.0.0.3"); !errors.As(err, &verr) || verr.Field != "username" {
		t.Errorf("reserved username: %v", err)
	}

	got, err := e.svc.Login(ctx, "IVAN_P", "secret-pass", "iPad", "10.0.0.1")
	if err != nil || got.User.ID != s.User.ID {
		t.Fatalf("login (case-insensitive username): %+v, %v", got.User, err)
	}
	if _, err := e.svc.Refresh(ctx, got.RefreshToken); err != nil {
		t.Errorf("session from login must refresh: %v", err)
	}

	for name, try := range map[string][2]string{
		"wrong password": {"ivan_p", "secret-pasS"},
		"unknown user":   {"nobody_here", "secret-pass"},
	} {
		if _, err := e.svc.Login(ctx, try[0], try[1], "", "10.0.0.1"); !errors.Is(err, ErrInvalidCredentials) {
			t.Errorf("%s: %v, want the same ErrInvalidCredentials", name, err)
		}
	}
}

func TestProviderAccountHasNoPassword(t *testing.T) {
	e := newTestEnv(t)
	tg := e.telegram(t, 42, "ivan_tg")
	if _, err := e.svc.Login(context.Background(), tg.User.Username, "anything-at-all", "", "1"); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("an Apple/Telegram account must not accept a password: %v", err)
	}
}

func TestLoginAttemptLimits(t *testing.T) {
	e := newTestEnv(t)
	e.svc.cfg.Limiter = &countingLimiter{counts: map[string]int{}}
	ctx := context.Background()
	if _, err := e.svc.Register(ctx, "target", "secret-pass", "", "10.0.0.1"); err != nil {
		t.Fatal(err)
	}

	for i := range loginPerUser {
		if _, err := e.svc.Login(ctx, "target", "guess", "", "10.0.0.9"); !errors.Is(err, ErrInvalidCredentials) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	// Even the right password waits out the window: the attacker cannot
	// tell a lucky guess from a lockout.
	if _, err := e.svc.Login(ctx, "TARGET", "secret-pass", "", "10.0.0.9"); !errors.Is(err, ErrRateLimited) {
		t.Errorf("after %d failures: %v, want ErrRateLimited", loginPerUser, err)
	}
}

func TestDeletedAccountCannotLogin(t *testing.T) {
	e := newTestEnv(t)
	ctx := context.Background()
	s, _ := e.svc.Register(ctx, "leaving", "secret-pass", "", "1")
	if err := user.NewStore(e.svc.store.db).Delete(ctx, s.User.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Login(ctx, "leaving", "secret-pass", "", "1"); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("deleted account: %v", err)
	}
	if _, err := e.svc.Register(ctx, "leaving", "new-secret", "", "2"); err != nil {
		t.Errorf("a deleted account's username must be free again: %v", err)
	}
}
