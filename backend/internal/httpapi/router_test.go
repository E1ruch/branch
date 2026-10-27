package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var discard = slog.New(slog.NewTextHandler(io.Discard, nil))

func newTestRouter(checks map[string]Check) http.Handler {
	return NewRouter(Deps{Logger: discard, RequestTimeout: time.Second, Checks: checks})
}

func do(t *testing.T, h http.Handler, method, path string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("%s %s: body is not JSON: %q", method, path, rec.Body.String())
	}
	return rec, body
}

func ok(context.Context) error   { return nil }
func fail(context.Context) error { return errors.New("connection refused") }

func TestHealthz(t *testing.T) {
	// Liveness must not depend on the database.
	rec, body := do(t, newTestRouter(map[string]Check{"postgres": fail}), http.MethodGet, "/healthz")
	if rec.Code != http.StatusOK || body["status"] != "ok" {
		t.Errorf("got %d %v, want 200 ok", rec.Code, body)
	}
}

func TestReadyz(t *testing.T) {
	t.Run("all ok", func(t *testing.T) {
		rec, body := do(t, newTestRouter(map[string]Check{"postgres": ok, "redis": ok}), http.MethodGet, "/readyz")
		if rec.Code != http.StatusOK || body["status"] != "ok" {
			t.Errorf("got %d %v, want 200 ok", rec.Code, body)
		}
	})
	t.Run("one fails", func(t *testing.T) {
		rec, body := do(t, newTestRouter(map[string]Check{"postgres": ok, "redis": fail}), http.MethodGet, "/readyz")
		if rec.Code != http.StatusServiceUnavailable {
			t.Errorf("status = %d, want 503", rec.Code)
		}
		checks := body["checks"].(map[string]any)
		if checks["postgres"] != "ok" || checks["redis"] != "fail" {
			t.Errorf("checks = %v", checks)
		}
		if strings.Contains(rec.Body.String(), "connection refused") {
			t.Error("readyz must not leak dependency errors")
		}
	})
}

func TestUnknownRouteIsJSON404(t *testing.T) {
	rec, body := do(t, newTestRouter(nil), http.MethodGet, "/v1/nope")
	errObj, _ := body["error"].(map[string]any)
	if rec.Code != http.StatusNotFound || errObj["code"] != "not_found" {
		t.Errorf("got %d %v, want 404 not_found", rec.Code, body)
	}
}

func TestRecovererReturnsJSON500(t *testing.T) {
	h := recoverer(discard)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))
	rec, body := do(t, h, http.MethodGet, "/")
	errObj, _ := body["error"].(map[string]any)
	if rec.Code != http.StatusInternalServerError || errObj["code"] != "internal" {
		t.Errorf("got %d %v, want 500 internal", rec.Code, body)
	}
}
