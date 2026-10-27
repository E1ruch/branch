// Package httpapi is the HTTP layer: routing, middleware and handlers.
package httpapi

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

type Deps struct {
	Logger         *slog.Logger
	RequestTimeout time.Duration
	Checks         map[string]Check
}

func NewRouter(d Deps) http.Handler {
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

	r.Route("/v1", func(r chi.Router) {
		// The timeout and gzip apply to plain request/response routes. The
		// WebSocket endpoint will be mounted next to this group, not inside it:
		// a long-lived connection must not be cut by the request timeout.
		r.Group(func(r chi.Router) {
			r.Use(middleware.Timeout(d.RequestTimeout))
			r.Use(middleware.Compress(5, "application/json"))
			// Domain routes (auth, feed, posts, ...) are mounted here.
		})
	})

	return r
}
