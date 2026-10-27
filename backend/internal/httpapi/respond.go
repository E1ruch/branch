package httpapi

import (
	"encoding/json"
	"net/http"
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
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorBody{Error: apiError{Code: code, Message: message}})
}
