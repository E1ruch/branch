// Package auth signs users in with Apple and Telegram and manages sessions:
// short-lived access JWTs plus rotating refresh tokens stored as hashes.
package auth

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/user"
)

var (
	ErrInvalidCredentials  = errors.New("auth: invalid credentials")
	ErrRefreshInvalid      = errors.New("auth: refresh token invalid")
	ErrRefreshReused       = errors.New("auth: refresh token reused")
	ErrProviderDisabled    = errors.New("auth: provider disabled")
	ErrProviderUnavailable = errors.New("auth: provider unavailable")
)

// ReplayGuard remembers one-time values. Claim returns false if key was
// already claimed within ttl.
type ReplayGuard interface {
	Claim(ctx context.Context, key string, ttl time.Duration) (bool, error)
}

type Config struct {
	RefreshTTL   time.Duration
	RefreshGrace time.Duration

	TelegramBotToken string // empty disables Telegram sign-in
	TelegramMaxAge   time.Duration

	// Limiter caps password attempts; nil disables the limits (tests).
	Limiter Limiter
}

// Limiter reports whether one more event for key fits in limit per window.
type Limiter interface {
	Allow(ctx context.Context, key string, limit int, window time.Duration) (bool, error)
}

type Service struct {
	store  store
	issuer *Issuer
	apple  *AppleVerifier
	replay ReplayGuard
	cfg    Config
	log    *slog.Logger
	now    func() time.Time
}

func NewService(db *pgxpool.Pool, issuer *Issuer, apple *AppleVerifier, replay ReplayGuard, cfg Config, log *slog.Logger) *Service {
	return &Service{
		store:  store{db: db},
		issuer: issuer,
		apple:  apple,
		replay: replay,
		cfg:    cfg,
		log:    log,
		now:    time.Now,
	}
}

type Tokens struct {
	AccessToken     string
	AccessExpiresAt time.Time
	RefreshToken    string
}

type Session struct {
	Tokens
	User      user.User
	IsNewUser bool // the app shows onboarding (pick a username)
}

func (s *Service) VerifyAccessToken(token string) (int64, error) {
	return s.issuer.Verify(token)
}

type AppleSignIn struct {
	IdentityToken string
	Nonce         string
	// Apple sends the name to the app only on the very first authorization.
	GivenName, FamilyName string
	DeviceName            string
}

func (s *Service) SignInWithApple(ctx context.Context, in AppleSignIn) (Session, error) {
	subject, err := s.apple.Verify(ctx, in.IdentityToken, in.Nonce)
	if err != nil {
		return Session{}, err
	}
	return s.signIn(ctx, "apple", subject, usernameCandidates(""), displayName(in.GivenName, in.FamilyName), in.DeviceName)
}

func (s *Service) SignInWithTelegram(ctx context.Context, data map[string]string, device string) (Session, error) {
	if s.cfg.TelegramBotToken == "" {
		return Session{}, ErrProviderDisabled
	}
	tg, err := VerifyTelegram(data, s.cfg.TelegramBotToken, s.now(), s.cfg.TelegramMaxAge)
	if err != nil {
		return Session{}, err
	}
	// Signed data stays valid for TelegramMaxAge: without this check anyone who
	// saw the callback URL could sign in with it again.
	fresh, err := s.replay.Claim(ctx, "telegram:"+data["hash"], s.cfg.TelegramMaxAge)
	if err != nil {
		return Session{}, err
	}
	if !fresh {
		return Session{}, errors.Join(ErrInvalidCredentials, errors.New("telegram data already used"))
	}
	subject := strconv.FormatInt(tg.ID, 10)
	return s.signIn(ctx, "telegram", subject, usernameCandidates(tg.Username), displayName(tg.FirstName, tg.LastName), device)
}

func (s *Service) signIn(ctx context.Context, provider, subject string, usernames []string, name *string, device string) (Session, error) {
	u, created, err := s.store.findOrCreateUser(ctx, provider, subject, usernames, name)
	if err != nil {
		return Session{}, err
	}
	if created {
		s.log.InfoContext(ctx, "user signed up", slog.Int64("user_id", u.ID), slog.String("provider", provider))
	}
	return s.startSession(ctx, u, created, device)
}

// startSession issues the token pair for a user who just proved who they are.
func (s *Service) startSession(ctx context.Context, u user.User, created bool, device string) (Session, error) {
	now := s.now()
	refresh, hash := newRefreshToken()
	if err := s.store.createRefreshToken(ctx, u.ID, hash, truncate(device, 64), now, now.Add(s.cfg.RefreshTTL)); err != nil {
		return Session{}, err
	}
	access, exp, err := s.issuer.Issue(u.ID)
	if err != nil {
		return Session{}, err
	}
	return Session{
		Tokens:    Tokens{AccessToken: access, AccessExpiresAt: exp, RefreshToken: refresh},
		User:      u,
		IsNewUser: created,
	}, nil
}

func (s *Service) Refresh(ctx context.Context, refreshToken string) (Tokens, error) {
	if refreshToken == "" {
		return Tokens{}, ErrRefreshInvalid
	}
	refresh, newHash := newRefreshToken()
	userID, err := s.store.rotateRefreshToken(ctx, hashRefreshToken(refreshToken), newHash, s.now(), s.cfg.RefreshTTL, s.cfg.RefreshGrace)
	if errors.Is(err, ErrRefreshReused) {
		s.log.WarnContext(ctx, "refresh token reuse, session family revoked")
	}
	if err != nil {
		return Tokens{}, err
	}
	access, exp, err := s.issuer.Issue(userID)
	if err != nil {
		return Tokens{}, err
	}
	return Tokens{AccessToken: access, AccessExpiresAt: exp, RefreshToken: refresh}, nil
}

func (s *Service) Logout(ctx context.Context, refreshToken string) error {
	if refreshToken == "" {
		return nil
	}
	return s.store.revokeFamily(ctx, hashRefreshToken(refreshToken), s.now())
}

func truncate(s string, max int) string {
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	return string([]rune(s)[:max])
}
