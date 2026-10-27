package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"vetka/internal/vote"
)

type voteHandlers struct {
	svc *vote.Service
	log *slog.Logger
}

type voteResponse struct {
	MyVote int `json:"my_vote"`
	Score  int `json:"score"`
}

// votePost handles PUT /v1/posts/{id}/vote {"value": -1|0|1}.
func (h *voteHandlers) votePost(w http.ResponseWriter, r *http.Request) {
	if id, ok := postID(w, r); ok {
		h.vote(w, r, id, h.svc.VotePost, "post not found")
	}
}

// voteComment handles PUT /v1/comments/{id}/vote {"value": -1|0|1}.
func (h *voteHandlers) voteComment(w http.ResponseWriter, r *http.Request) {
	if id, ok := commentID(w, r); ok {
		h.vote(w, r, id, h.svc.VoteComment, "comment not found")
	}
}

// vote is shared by both targets. The value is required: a body that lost
// its field must not silently clear the vote.
func (h *voteHandlers) vote(w http.ResponseWriter, r *http.Request, id int64,
	cast func(ctx context.Context, userID, id int64, value int) (vote.Result, error), notFound string) {
	var req struct {
		Value *int `json:"value"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Value == nil {
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", "value", "value is required: -1, 0 or 1")
		return
	}

	res, err := cast(r.Context(), viewer(r), id, *req.Value)
	switch {
	case errors.Is(err, vote.ErrInvalidValue):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", "value", "value must be -1, 0 or 1")
	case errors.Is(err, vote.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", notFound)
	case errors.Is(err, vote.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many votes, slow down")
	case err != nil:
		internalError(w, r, h.log, err)
	default:
		writeJSON(w, http.StatusOK, voteResponse{MyVote: res.MyVote, Score: res.Score})
	}
}
