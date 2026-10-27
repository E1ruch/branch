package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
)

// page is the envelope of every paginated list. next_cursor is null on the
// last page.
type page[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

// Cursors are opaque to the client (base64 JSON): the server can change what
// a list is sorted by without breaking app versions already in the store.
func encodeCursor(v any) *string {
	b, _ := json.Marshal(v)
	s := base64.RawURLEncoding.EncodeToString(b)
	return &s
}

// decodeCursor reads ?cursor= into dst. It returns false when absent.
func decodeCursor(r *http.Request, dst any) (bool, error) {
	raw := r.URL.Query().Get("cursor")
	if raw == "" {
		return false, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil || json.Unmarshal(b, dst) != nil {
		return false, errors.New("malformed cursor")
	}
	return true, nil
}

const (
	defaultLimit = 25
	maxLimit     = 100
)

func parseLimit(r *http.Request) (int, error) {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return defaultLimit, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > maxLimit {
		return 0, errors.New("limit must be 1-100")
	}
	return n, nil
}
