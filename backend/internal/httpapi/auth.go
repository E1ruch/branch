package httpapi

import (
	"errors"
	"html/template"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"vetka/internal/auth"
	"vetka/internal/user"
)

type authHandlers struct {
	svc *auth.Service
	log *slog.Logger
}

type tokensResponse struct {
	AccessToken     string    `json:"access_token"`
	AccessExpiresAt time.Time `json:"access_expires_at"`
	RefreshToken    string    `json:"refresh_token"`
}

type sessionResponse struct {
	tokensResponse
	User      userDTO `json:"user"`
	IsNewUser bool    `json:"is_new_user"`
}

type userDTO struct {
	ID           int64     `json:"id"`
	Username     string    `json:"username"`
	DisplayName  *string   `json:"display_name"`
	Bio          *string   `json:"bio"`
	PostKarma    int       `json:"post_karma"`
	CommentKarma int       `json:"comment_karma"`
	CreatedAt    time.Time `json:"created_at"`
}

func toUserDTO(u user.User) userDTO {
	return userDTO{
		ID:           u.ID,
		Username:     u.Username,
		DisplayName:  u.DisplayName,
		Bio:          u.Bio,
		PostKarma:    u.PostKarma,
		CommentKarma: u.CommentKarma,
		CreatedAt:    u.CreatedAt,
	}
}

func toTokensResponse(t auth.Tokens) tokensResponse {
	return tokensResponse{AccessToken: t.AccessToken, AccessExpiresAt: t.AccessExpiresAt, RefreshToken: t.RefreshToken}
}

func toSessionResponse(s auth.Session) sessionResponse {
	return sessionResponse{tokensResponse: toTokensResponse(s.Tokens), User: toUserDTO(s.User), IsNewUser: s.IsNewUser}
}

func (h *authHandlers) apple(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IdentityToken string `json:"identity_token"`
		Nonce         string `json:"nonce"`
		GivenName     string `json:"given_name"`
		FamilyName    string `json:"family_name"`
		DeviceName    string `json:"device_name"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	session, err := h.svc.SignInWithApple(r.Context(), auth.AppleSignIn{
		IdentityToken: req.IdentityToken,
		Nonce:         req.Nonce,
		GivenName:     req.GivenName,
		FamilyName:    req.FamilyName,
		DeviceName:    req.DeviceName,
	})
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toSessionResponse(session))
}

func (h *authHandlers) telegram(w http.ResponseWriter, r *http.Request) {
	var req struct {
		// The callback query parameters exactly as Telegram sent them.
		Data       map[string]string `json:"data"`
		DeviceName string            `json:"device_name"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	session, err := h.svc.SignInWithTelegram(r.Context(), req.Data, req.DeviceName)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toSessionResponse(session))
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (h *authHandlers) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	tokens, err := h.svc.Refresh(r.Context(), req.RefreshToken)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toTokensResponse(tokens))
}

func (h *authHandlers) logout(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := h.svc.Logout(r.Context(), req.RefreshToken); err != nil {
		h.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// fail maps auth errors to stable codes. The client signs out on
// refresh_invalid and shows a retry on provider_unavailable.
func (h *authHandlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, auth.ErrInvalidCredentials):
		h.log.InfoContext(r.Context(), "sign-in rejected", slog.Any("err", err))
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "sign-in data is invalid or expired")
	case errors.Is(err, auth.ErrRefreshInvalid), errors.Is(err, auth.ErrRefreshReused):
		writeError(w, http.StatusUnauthorized, "refresh_invalid", "session expired, sign in again")
	case errors.Is(err, auth.ErrProviderDisabled):
		writeError(w, http.StatusNotFound, "provider_disabled", "this sign-in method is disabled")
	case errors.Is(err, auth.ErrProviderUnavailable):
		h.log.WarnContext(r.Context(), "auth provider unavailable", slog.Any("err", err))
		writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "sign-in provider is unavailable, try again")
	default:
		internalError(w, r, h.log, err)
	}
}

// authenticate resolves the bearer token, if any. No header means an
// anonymous request; a bad header is rejected right away even on public
// routes, so the client refreshes instead of silently browsing logged out.
func authenticate(verify func(string) (int64, error)) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			if header == "" {
				next.ServeHTTP(w, r)
				return
			}
			token, ok := strings.CutPrefix(header, "Bearer ")
			if !ok {
				writeError(w, http.StatusUnauthorized, "unauthorized", "expected a Bearer token")
				return
			}
			id, err := verify(token)
			if errors.Is(err, auth.ErrTokenExpired) {
				writeError(w, http.StatusUnauthorized, "token_expired", "access token expired, refresh it")
				return
			}
			if err != nil {
				writeError(w, http.StatusUnauthorized, "unauthorized", "access token is invalid")
				return
			}
			next.ServeHTTP(w, r.WithContext(auth.WithUserID(r.Context(), id)))
		})
	}
}

func requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := auth.UserID(r.Context()); !ok {
			writeError(w, http.StatusUnauthorized, "unauthorized", "sign in required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// --- Telegram web flow -----------------------------------------------------
//
// The app opens /auth/telegram in ASWebAuthenticationSession. The page shows
// the Telegram Login Widget, which redirects to /auth/telegram/callback with
// signed query parameters. The callback forwards them unchanged to the app's
// URL scheme; the app then POSTs them to /v1/auth/telegram for verification.

type telegramPage struct {
	botUsername   string // empty disables the flow
	publicBaseURL string
	appScheme     string
}

var telegramPageTmpl = template.Must(template.New("tg").Parse(`<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Вход через Telegram</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         font-family: -apple-system, system-ui, sans-serif; background: Canvas; }
</style>
</head>
<body>
<script async src="https://telegram.org/js/telegram-widget.js?22"
        data-telegram-login="{{.Bot}}" data-size="large" data-radius="12"
        data-auth-url="{{.CallbackURL}}"></script>
</body>
</html>
`))

func (p telegramPage) page(w http.ResponseWriter, _ *http.Request) {
	if p.botUsername == "" {
		writeError(w, http.StatusNotFound, "provider_disabled", "this sign-in method is disabled")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = telegramPageTmpl.Execute(w, struct{ Bot, CallbackURL string }{
		Bot:         p.botUsername,
		CallbackURL: strings.TrimRight(p.publicBaseURL, "/") + "/auth/telegram/callback",
	})
}

func (p telegramPage) callback(w http.ResponseWriter, r *http.Request) {
	if p.botUsername == "" || r.URL.Query().Get("hash") == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "missing Telegram data")
		return
	}
	target := url.URL{Scheme: p.appScheme, Host: "auth", Path: "/telegram", RawQuery: r.URL.RawQuery}
	http.Redirect(w, r, target.String(), http.StatusFound)
}
