package httpapi

import (
	"errors"
	"log/slog"
	"net/http"

	"vetka/internal/auth"
	"vetka/internal/user"
)

type meHandlers struct {
	users *user.Store
	log   *slog.Logger
}

func (h *meHandlers) get(w http.ResponseWriter, r *http.Request) {
	id, _ := auth.UserID(r.Context())
	u, err := h.users.Get(r.Context(), id)
	if errors.Is(err, user.ErrNotFound) {
		// Token outlived the account (deleted within the access TTL).
		writeError(w, http.StatusUnauthorized, "unauthorized", "account not found")
		return
	}
	if err != nil {
		internalError(w, r, h.log, err)
		return
	}
	writeJSON(w, http.StatusOK, toUserDTO(u))
}
