package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"sync"
	"time"
)

// Check reports whether a dependency is usable.
type Check func(ctx context.Context) error

// healthz is liveness: the process is up. It never touches dependencies, so a
// database outage does not make the orchestrator restart every API instance.
func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz is readiness: all dependencies answer. Checks run in parallel, and
// the body says only ok/fail per check; the error itself goes to the log,
// since this endpoint is public.
func readyz(log *slog.Logger, checks map[string]Check) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		var (
			mu      sync.Mutex
			wg      sync.WaitGroup
			results = make(map[string]string, len(checks))
			ready   = true
		)
		for name, check := range checks {
			wg.Go(func() {
				err := check(ctx)
				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					ready = false
					results[name] = "fail"
					log.WarnContext(ctx, "readiness check failed", slog.String("check", name), slog.Any("err", err))
					return
				}
				results[name] = "ok"
			})
		}
		wg.Wait()

		status, text := http.StatusOK, "ok"
		if !ready {
			status, text = http.StatusServiceUnavailable, "unavailable"
		}
		writeJSON(w, status, map[string]any{"status": text, "checks": results})
	}
}
