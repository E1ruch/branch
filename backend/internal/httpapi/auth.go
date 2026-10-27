package httpapi

import (
	"errors"
	"log/slog"
	"net"
	"net/http"
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
type passwordRequest struct {
	Username   string `json:"username"`
	Password   string `json:"password"`
	DeviceName string `json:"device_name"`
}

// register: POST /v1/auth/register {"username", "password", "device_name"}.
func (h *authHandlers) register(w http.ResponseWriter, r *http.Request) {
	var req passwordRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	session, err := h.svc.Register(r.Context(), req.Username, req.Password, req.DeviceName, clientAddr(r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, toSessionResponse(session))
}

// login: POST /v1/auth/login {"username", "password", "device_name"}.
func (h *authHandlers) login(w http.ResponseWriter, r *http.Request) {
	var req passwordRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	session, err := h.svc.Login(r.Context(), req.Username, req.Password, req.DeviceName, clientAddr(r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toSessionResponse(session))
}

// clientAddr identifies the client for attempt limits. The API is not behind
// a proxy yet; once it is, this must read the proxy's forwarded address.
func clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (h *authHandlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	var verr *user.ValidationError
	switch {
	case errors.As(err, &verr):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", verr.Field, verr.Message)
	case errors.Is(err, user.ErrUsernameTaken):
		writeFieldError(w, http.StatusConflict, "username_taken", "username", "this username is taken")
	case errors.Is(err, auth.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many attempts, try again later")
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
