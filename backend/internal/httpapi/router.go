// Package httpapi is the HTTP layer: routing, middleware and handlers.
package httpapi

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"vetka/internal/auth"
	"vetka/internal/community"
	"vetka/internal/user"
)

type Deps struct {
	Logger         *slog.Logger
	RequestTimeout time.Duration
	Checks         map[string]Check

	Auth        *auth.Service
	Users       *user.Store
	Communities *community.Service

	TelegramBot   string // bot username for the login widget; empty disables it
	PublicBaseURL string // where the API is reachable from a browser
	AppScheme     string // the app's URL scheme for auth redirects
}

func NewRouter(d Deps) http.Handler {
	authH := &authHandlers{svc: d.Auth, log: d.Logger}
	meH := &meHandlers{users: d.Users, log: d.Logger}
	commH := &communityHandlers{svc: d.Communities, log: d.Logger}
	tg := telegramPage{botUsername: d.TelegramBot, publicBaseURL: d.PublicBaseURL, appScheme: d.AppScheme}

	r := chi.NewRouter()
	r.Use(middleware.RequestID, requestLogger(d.Logger), recoverer(d.Logger))

	r.NotFound(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	})
	r.MethodNotAllowed(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	})

	r.Get("/healthz", healthz)
	r.Get("/readyz", readyz(d.Logger, d.Checks))

	// Browser pages for the Telegram web sign-in flow, outside the JSON API.
	r.Get("/auth/telegram", tg.page)
	r.Get("/auth/telegram/callback", tg.callback)

	r.Route("/v1", func(r chi.Router) {
		r.Use(authenticate(d.Auth.VerifyAccessToken))

		// The timeout and gzip apply to plain request/response routes. The
		// WebSocket endpoint will be mounted next to this group, not inside it:
		// a long-lived connection must not be cut by the request timeout.
		r.Group(func(r chi.Router) {
			r.Use(middleware.Timeout(d.RequestTimeout))
			r.Use(middleware.Compress(5, "application/json"))

			r.Route("/auth", func(r chi.Router) {
				r.Post("/apple", authH.apple)
				r.Post("/telegram", authH.telegram)
				r.Post("/refresh", authH.refresh)
				r.Post("/logout", authH.logout)
			})

			r.With(requireAuth).Get("/me", meH.get)
			r.With(requireAuth).Get("/me/subscriptions", commH.subscriptions)

			r.Route("/communities", func(r chi.Router) {
				r.Get("/", commH.list)
				r.Get("/search", commH.search)
				r.With(requireAuth).Post("/", commH.create)
				r.Route("/{slug}", func(r chi.Router) {
					r.Get("/", commH.get)
					r.With(requireAuth).Patch("/", commH.update)
					// PUT/DELETE of a state, not a toggle: retries are safe.
					r.With(requireAuth).Put("/subscription", commH.subscribe)
					r.With(requireAuth).Delete("/subscription", commH.unsubscribe)
				})
			})
		})
	})

	return r
}
