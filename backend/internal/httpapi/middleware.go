package httpapi

import (
	"log/slog"
	"net/http"
	"runtime/debug"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// requestLogger logs one line per request. It sits outside recoverer, so a
// panic is logged with the 500 that recoverer wrote.
func requestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			next.ServeHTTP(ww, r)

			status := ww.Status()
			if status == 0 {
				status = http.StatusOK
			}
			level := slog.LevelInfo
			switch {
			case status >= 500:
				level = slog.LevelError
			case r.URL.Path == "/healthz" || r.URL.Path == "/readyz":
				level = slog.LevelDebug
			}

			log.LogAttrs(r.Context(), level, "http request",
				slog.String("method", r.Method),
				// The route pattern (/v1/posts/{id}) groups well in metrics; the path does not.
				slog.String("route", chi.RouteContext(r.Context()).RoutePattern()),
				slog.String("path", r.URL.Path),
				slog.Int("status", status),
				slog.Int("bytes", ww.BytesWritten()),
				slog.Duration("duration", time.Since(start)),
				slog.String("request_id", middleware.GetReqID(r.Context())),
			)
		})
	}
}

// recoverer turns a handler panic into a JSON 500 instead of a dropped connection.
func recoverer(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				rec := recover()
				if rec == nil {
					return
				}
				if rec == http.ErrAbortHandler {
					panic(rec) // the server handles this one itself
				}
				log.ErrorContext(r.Context(), "handler panic",
					slog.Any("panic", rec),
					slog.String("stack", string(debug.Stack())),
					slog.String("request_id", middleware.GetReqID(r.Context())),
				)
				writeError(w, http.StatusInternalServerError, "internal", "internal server error")
			}()
			next.ServeHTTP(w, r)
		})
	}
}
