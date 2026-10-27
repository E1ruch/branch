package httpapi

import (
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

// votePost handles PUT /v1/posts/{id}/vote {"value": -1|0|1}. The value is
// required: a body that lost its field must not silently clear the vote.
func (h *voteHandlers) votePost(w http.ResponseWriter, r *http.Request) {
	id, ok := postID(w, r)
	if !ok {
		return
	}
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

	res, err := h.svc.VotePost(r.Context(), viewer(r), id, *req.Value)
	switch {
	case errors.Is(err, vote.ErrInvalidValue):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", "value", "value must be -1, 0 or 1")
	case errors.Is(err, vote.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "post not found")
	case errors.Is(err, vote.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many votes, slow down")
	case err != nil:
		internalError(w, r, h.log, err)
	default:
		writeJSON(w, http.StatusOK, voteResponse{MyVote: res.MyVote, Score: res.Score})
	}
}
