package httpapi

import (
	"log/slog"
	"net/http"

	"vetka/internal/post"
	"vetka/internal/search"
	"vetka/internal/user"
)

// searchHandlers serve the search screen: people, posts and the popular
// queries. Communities are searched at /v1/communities/search.
type searchHandlers struct {
	svc   *search.Service
	users *user.Store
	posts *post.Service
	log   *slog.Logger
}

const searchLimit = 25

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

func (h *searchHandlers) postResults(w http.ResponseWriter, r *http.Request) {
	items, err := h.posts.Search(r.Context(), r.URL.Query().Get("q"), viewer(r), searchLimit)
	if err != nil {
		internalError(w, r, h.log, err)
		return
	}
	resp := page[postDTO]{Items: make([]postDTO, len(items))}
	for i, p := range items {
		resp.Items[i] = toPostDTO(p)
	}
	writeJSON(w, http.StatusOK, resp)
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
