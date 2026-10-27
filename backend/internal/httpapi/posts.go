package httpapi

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"vetka/internal/post"
)

type postHandlers struct {
	svc *post.Service
	log *slog.Logger
}

type postDTO struct {
	ID            int64          `json:"id"`
	Title         string         `json:"title"`
	Body          string         `json:"body"`
	BodyTruncated bool           `json:"body_truncated"`
	IsNSFW        bool           `json:"is_nsfw"`
	Score         int            `json:"score"`
	CommentCount  int            `json:"comment_count"`
	MyVote        int            `json:"my_vote"`
	CreatedAt     time.Time      `json:"created_at"`
	EditedAt      *time.Time     `json:"edited_at"`
	Community     postCommunity  `json:"community"`
	Author        *postAuthorDTO `json:"author"`
}

type postCommunity struct {
	ID    int64  `json:"id"`
	Slug  string `json:"slug"`
	Title string `json:"title"`
}

type postAuthorDTO struct {
	ID          int64   `json:"id"`
	Username    string  `json:"username"`
	DisplayName *string `json:"display_name"`
}

func toPostDTO(p post.Post) postDTO {
	dto := postDTO{
		ID:            p.ID,
		Title:         p.Title,
		Body:          p.Body,
		BodyTruncated: p.BodyTruncated,
		IsNSFW:        p.IsNSFW,
		Score:         p.Score,
		CommentCount:  p.CommentCount,
		MyVote:        p.MyVote,
		CreatedAt:     p.CreatedAt,
		EditedAt:      p.EditedAt,
		Community:     postCommunity{ID: p.Community.ID, Slug: p.Community.Slug, Title: p.Community.Title},
	}
	if p.Author != nil {
		dto.Author = &postAuthorDTO{ID: p.Author.ID, Username: p.Author.Username, DisplayName: p.Author.DisplayName}
	}
	return dto
}

// feedQuery parses ?sort=hot|new&cursor=&limit= shared by all feeds.
func feedQuery(w http.ResponseWriter, r *http.Request) (post.FeedQuery, bool) {
	sort, ok := post.ParseSort(r.URL.Query().Get("sort"))
	if !ok {
		writeError(w, http.StatusBadRequest, "bad_request", "sort must be hot or new")
		return post.FeedQuery{}, false
	}
	limit, err := parseLimit(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return post.FeedQuery{}, false
	}
	var cur post.Cursor
	has, err := decodeCursor(r, &cur)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return post.FeedQuery{}, false
	}
	q := post.FeedQuery{Sort: sort, Limit: limit, Viewer: viewer(r)}
	if has {
		q.After = &cur
	}
	return q, true
}

func (h *postHandlers) writeFeed(w http.ResponseWriter, r *http.Request, q post.FeedQuery, items []post.Post, err error) {
	if err != nil {
		h.fail(w, r, err)
		return
	}
	resp := page[postDTO]{Items: make([]postDTO, len(items))}
	for i, p := range items {
		resp.Items[i] = toPostDTO(p)
	}
	if len(items) == q.Limit {
		resp.NextCursor = encodeCursor(post.CursorAfter(items[len(items)-1]))
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *postHandlers) feedAll(w http.ResponseWriter, r *http.Request) {
	if q, ok := feedQuery(w, r); ok {
		items, err := h.svc.FeedAll(r.Context(), q)
		h.writeFeed(w, r, q, items, err)
	}
}

func (h *postHandlers) feedSubscriptions(w http.ResponseWriter, r *http.Request) {
	if q, ok := feedQuery(w, r); ok {
		items, err := h.svc.FeedSubscriptions(r.Context(), viewer(r), q)
		h.writeFeed(w, r, q, items, err)
	}
}

func (h *postHandlers) feedCommunity(w http.ResponseWriter, r *http.Request) {
	if q, ok := feedQuery(w, r); ok {
		items, err := h.svc.FeedCommunity(r.Context(), chi.URLParam(r, "slug"), q)
		h.writeFeed(w, r, q, items, err)
	}
}

func (h *postHandlers) create(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title  string `json:"title"`
		Body   string `json:"body"`
		IsNSFW bool   `json:"is_nsfw"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	p, err := h.svc.Create(r.Context(), viewer(r), chi.URLParam(r, "slug"),
		post.CreateInput{Title: req.Title, Body: req.Body, IsNSFW: req.IsNSFW})
	h.respond(w, r, http.StatusCreated, p, err)
}

func (h *postHandlers) get(w http.ResponseWriter, r *http.Request) {
	id, ok := postID(w, r)
	if !ok {
		return
	}
	p, err := h.svc.Get(r.Context(), id, viewer(r))
	h.respond(w, r, http.StatusOK, p, err)
}

func (h *postHandlers) edit(w http.ResponseWriter, r *http.Request) {
	id, ok := postID(w, r)
	if !ok {
		return
	}
	var req struct {
		Body string `json:"body"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	p, err := h.svc.Edit(r.Context(), id, viewer(r), req.Body)
	h.respond(w, r, http.StatusOK, p, err)
}

func (h *postHandlers) delete(w http.ResponseWriter, r *http.Request) {
	id, ok := postID(w, r)
	if !ok {
		return
	}
	if err := h.svc.Delete(r.Context(), id, viewer(r)); err != nil {
		h.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func postID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, http.StatusNotFound, "not_found", "post not found")
		return 0, false
	}
	return id, true
}

func (h *postHandlers) respond(w http.ResponseWriter, r *http.Request, status int, p post.Post, err error) {
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, status, toPostDTO(p))
}

func (h *postHandlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	var verr *post.ValidationError
	switch {
	case errors.As(err, &verr):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", verr.Field, verr.Message)
	case errors.Is(err, post.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "post not found")
	case errors.Is(err, post.ErrCommunityNotFound):
		writeError(w, http.StatusNotFound, "not_found", "community not found")
	case errors.Is(err, post.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", "only the author can do this")
	case errors.Is(err, post.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many posts, try again later")
	default:
		internalError(w, r, h.log, err)
	}
}
