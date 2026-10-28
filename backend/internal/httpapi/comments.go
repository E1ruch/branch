package httpapi

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"vetka/internal/comment"
)

type commentHandlers struct {
	svc *comment.Service
	log *slog.Logger
}

type commentDTO struct {
	ID         int64          `json:"id"`
	PostID     int64          `json:"post_id"`
	ParentID   *int64         `json:"parent_id"`
	Depth      int            `json:"depth"`
	Body       *string        `json:"body"` // null for a deleted comment
	IsDeleted  bool           `json:"is_deleted"`
	Author     *postAuthorDTO `json:"author"`
	Score      int            `json:"score"`
	MyVote     int            `json:"my_vote"`
	ReplyCount int            `json:"reply_count"`
	CreatedAt  time.Time      `json:"created_at"`
	EditedAt   *time.Time     `json:"edited_at"`
}

// threadItemDTO is one row of a thread: a comment, or a stub the app turns
// into "ещё N ответов" (kind=more) or "продолжить ветку" (kind=continue).
type threadItemDTO struct {
	Kind    string      `json:"kind"`
	Comment *commentDTO `json:"comment,omitempty"`

	ParentID int64   `json:"parent_id,omitempty"`
	Depth    int     `json:"depth,omitempty"`
	Count    int     `json:"count,omitempty"`
	Cursor   *string `json:"cursor,omitempty"`
}

func toCommentDTO(c comment.Comment) commentDTO {
	dto := commentDTO{
		ID:         c.ID,
		PostID:     c.PostID,
		ParentID:   c.ParentID,
		Depth:      c.Depth,
		IsDeleted:  c.Deleted,
		Score:      c.Score,
		MyVote:     c.MyVote,
		ReplyCount: c.ReplyCount,
		CreatedAt:  c.CreatedAt,
		EditedAt:   c.EditedAt,
	}
	if !c.Deleted {
		dto.Body = &c.Body
	}
	if c.Author != nil {
		dto.Author = &postAuthorDTO{ID: c.Author.ID, Username: c.Author.Username, DisplayName: c.Author.DisplayName}
	}
	return dto
}

func toThreadDTO(p comment.Page) page[threadItemDTO] {
	out := page[threadItemDTO]{Items: make([]threadItemDTO, len(p.Items))}
	for i, it := range p.Items {
		if it.Kind == comment.KindComment {
			c := toCommentDTO(*it.Comment)
			out.Items[i] = threadItemDTO{Kind: string(it.Kind), Comment: &c}
			continue
		}
		dto := threadItemDTO{Kind: string(it.Kind), ParentID: it.ParentID, Depth: it.Depth, Count: it.Count}
		if it.After != nil {
			dto.Cursor = encodeCursor(*it.After)
		}
		out.Items[i] = dto
	}
	if p.Next != nil {
		out.NextCursor = encodeCursor(*p.Next)
	}
	return out
}

func threadQuery(w http.ResponseWriter, r *http.Request) (comment.Query, bool) {
	sort, ok := comment.ParseSort(r.URL.Query().Get("sort"))
	if !ok {
		writeError(w, http.StatusBadRequest, "bad_request", "sort must be best or new")
		return comment.Query{}, false
	}
	limit, err := parseLimit(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return comment.Query{}, false
	}
	var cur comment.Cursor
	has, err := decodeCursor(r, &cur)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return comment.Query{}, false
	}
	q := comment.Query{Sort: sort, Limit: limit, Viewer: viewer(r)}
	if has {
		q.After = &cur
	}
	return q, true
}

// thread: GET /v1/posts/{id}/comments
func (h *commentHandlers) thread(w http.ResponseWriter, r *http.Request) {
	postID, ok := postID(w, r)
	if !ok {
		return
	}
	q, ok := threadQuery(w, r)
	if !ok {
		return
	}
	p, err := h.svc.Thread(r.Context(), postID, q)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toThreadDTO(p))
}

// get: GET /v1/comments/{id} — the head of a "продолжить ветку" screen.
func (h *commentHandlers) get(w http.ResponseWriter, r *http.Request) {
	id, ok := commentID(w, r)
	if !ok {
		return
	}
	c, err := h.svc.Get(r.Context(), id, viewer(r))
	h.respond(w, r, http.StatusOK, c, err)
}

// replies: GET /v1/comments/{id}/replies — both "more" and "continue".
func (h *commentHandlers) replies(w http.ResponseWriter, r *http.Request) {
	id, ok := commentID(w, r)
	if !ok {
		return
	}
	q, ok := threadQuery(w, r)
	if !ok {
		return
	}
	p, err := h.svc.Replies(r.Context(), id, q)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toThreadDTO(p))
}

// create: POST /v1/posts/{id}/comments {"body": "...", "parent_id": 123?}
func (h *commentHandlers) create(w http.ResponseWriter, r *http.Request) {
	postID, ok := postID(w, r)
	if !ok {
		return
	}
	var req struct {
		Body     string `json:"body"`
		ParentID *int64 `json:"parent_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	c, err := h.svc.Create(r.Context(), viewer(r), postID, req.ParentID, req.Body)
	h.respond(w, r, http.StatusCreated, c, err)
}

func (h *commentHandlers) edit(w http.ResponseWriter, r *http.Request) {
	id, ok := commentID(w, r)
	if !ok {
		return
	}
	var req struct {
		Body string `json:"body"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	c, err := h.svc.Edit(r.Context(), id, viewer(r), req.Body)
	h.respond(w, r, http.StatusOK, c, err)
}

func (h *commentHandlers) delete(w http.ResponseWriter, r *http.Request) {
	id, ok := commentID(w, r)
	if !ok {
		return
	}
	if err := h.svc.Delete(r.Context(), id, viewer(r)); err != nil {
		h.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func commentID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, http.StatusNotFound, "not_found", "comment not found")
		return 0, false
	}
	return id, true
}

func (h *commentHandlers) respond(w http.ResponseWriter, r *http.Request, status int, c comment.Comment, err error) {
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, status, toCommentDTO(c))
}

func (h *commentHandlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	var verr *comment.ValidationError
	switch {
	case errors.As(err, &verr):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", verr.Field, verr.Message)
	case errors.Is(err, comment.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "comment not found")
	case errors.Is(err, comment.ErrPostNotFound):
		writeError(w, http.StatusNotFound, "not_found", "post not found")
	case errors.Is(err, comment.ErrParentNotFound):
		writeFieldError(w, http.StatusUnprocessableEntity, "parent_not_found", "parent_id", "the comment you reply to is gone")
	case errors.Is(err, comment.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", "only the author can do this")
	case errors.Is(err, comment.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many comments, try again later")
	default:
		internalError(w, r, h.log, err)
	}
}
