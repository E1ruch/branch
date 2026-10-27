package httpapi

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5/middleware"
)

// Every error has the same shape: {"error": {"code": "...", "message": "..."}}.
// The iOS client picks the localized text by the stable snake_case code;
// message is for developers only.
type errorBody struct {
	Error apiError `json:"error"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	// Field names the offending input, so the app highlights that text field.
	Field string `json:"field,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorBody{Error: apiError{Code: code, Message: message}})
}

func writeFieldError(w http.ResponseWriter, status int, code, field, message string) {
	writeJSON(w, status, errorBody{Error: apiError{Code: code, Message: message, Field: field}})
}

// internalError logs the real cause and hides it from the client.
func internalError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	log.ErrorContext(r.Context(), "request failed",
		slog.Any("err", err),
		slog.String("request_id", middleware.GetReqID(r.Context())),
	)
	writeError(w, http.StatusInternalServerError, "internal", "internal server error")
}

// decodeJSON reads a small JSON body. Unknown fields are allowed so older
// servers accept requests from newer app versions.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "malformed JSON body")
		return false
	}
	return true
}
