package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"vetka/internal/search"
	"vetka/internal/user"
)

// searchHandlers serve the search screen: people, posts and the popular
// queries. Communities are searched at /v1/communities/search.
type searchHandlers struct {
	svc   *search.Service
	users *user.Store
	posts *postHandlers // search results are a feed page like any other
	log   *slog.Logger
}

const searchLimit = 25

// Limiter caps requests per key and window (Redis in production).
type Limiter interface {
	Allow(ctx context.Context, key string, limit int, window time.Duration) (bool, error)
}

const (
	// One typed query costs three requests (communities, people, posts),
	// after a 300 ms pause in typing: 90 a minute is 30 searches, far more
	// than a person makes and far less than a script needs to hurt.
	searchRequestsPerWindow = 90
	searchWindow            = time.Minute
)

// limitSearch caps search requests per account, or per address for anonymous
// ones. A broken limiter lets requests through: search is not worth an
// outage.
func limitSearch(l Limiter, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		if l == nil {
			return next
		}
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := "search:ip:" + clientAddr(r)
			if id := viewer(r); id != 0 {
				key = "search:user:" + strconv.FormatInt(id, 10)
			}
			ok, err := l.Allow(r.Context(), key, searchRequestsPerWindow, searchWindow)
			if err != nil {
				log.WarnContext(r.Context(), "search limiter failed", slog.Any("err", err))
			} else if !ok {
				writeError(w, http.StatusTooManyRequests, "rate_limited", "too many searches, try again in a minute")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func (h *searchHandlers) people(w http.ResponseWriter, r *http.Request) {
	items, err := h.users.Search(r.Context(), r.URL.Query().Get("q"), searchLimit)
	if err != nil {
		internalError(w, r, h.log, err)
		return
	}
	resp := page[userDTO]{Items: make([]userDTO, len(items))}
	for i, u := range items {
		resp.Items[i] = toUserDTO(u)
	}
	writeJSON(w, http.StatusOK, resp)
}

// postResults: GET /v1/search/posts?q=&cursor= — hottest matches first,
// paged like a feed.
func (h *searchHandlers) postResults(w http.ResponseWriter, r *http.Request) {
	q, ok := feedQuery(w, r)
	if !ok {
		return
	}
	items, err := h.posts.svc.Search(r.Context(), r.URL.Query().Get("q"), q)
	h.posts.writeFeed(w, r, q, items, err)
}

// popular: GET /v1/search/popular → {"items": ["юмор", "игры", …]}.
func (h *searchHandlers) popular(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Popular(r.Context(), 8)
	if err != nil {
		internalError(w, r, h.log, err)
		return
	}
	writeJSON(w, http.StatusOK, page[string]{Items: items})
}

// record: POST /v1/search/queries {"query"} when a search was meant (Return,
// or a result opened). 204 even for queries too short to keep.
func (h *searchHandlers) record(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Query string `json:"query"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := h.svc.Record(r.Context(), viewer(r), req.Query); err != nil {
		internalError(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
