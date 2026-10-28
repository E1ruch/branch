package httpapi

import (
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"vetka/internal/auth"
	"vetka/internal/community"
)

type communityHandlers struct {
	svc *community.Service
	log *slog.Logger
}

type communityDTO struct {
	ID               int64     `json:"id"`
	Slug             string    `json:"slug"`
	Title            string    `json:"title"`
	Description      string    `json:"description"`
	IsNSFW           bool      `json:"is_nsfw"`
	SubscribersCount int       `json:"subscribers_count"`
	CreatedAt        time.Time `json:"created_at"`
	IsSubscribed     bool      `json:"is_subscribed"`
	ViewerRole       *string   `json:"viewer_role"`
	// Present on a single community only; lists leave it out.
	Rules *[]ruleDTO `json:"rules,omitempty"`
}

type ruleDTO struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

func toCommunityDTO(c community.Community) communityDTO {
	dto := communityDTO{
		ID:               c.ID,
		Slug:             c.Slug,
		Title:            c.Title,
		Description:      c.Description,
		IsNSFW:           c.IsNSFW,
		SubscribersCount: c.SubscribersCount,
		CreatedAt:        c.CreatedAt,
		IsSubscribed:     c.IsSubscribed,
		ViewerRole:       c.ViewerRole,
	}
	if c.Rules != nil {
		rules := make([]ruleDTO, len(c.Rules))
		for i, r := range c.Rules {
			rules[i] = ruleDTO(r)
		}
		dto.Rules = &rules
	}
	return dto
}

func toCommunityDTOs(cs []community.Community) []communityDTO {
	out := make([]communityDTO, len(cs))
	for i, c := range cs {
		out[i] = toCommunityDTO(c)
	}
	return out
}

// viewer is the signed-in user or 0 for anonymous requests.
func viewer(r *http.Request) int64 {
	id, _ := auth.UserID(r.Context())
	return id
}

func (h *communityHandlers) list(w http.ResponseWriter, r *http.Request) {
	limit, err := parseLimit(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var cur community.PopularCursor
	hasCursor, err := decodeCursor(r, &cur)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var after *community.PopularCursor
	if hasCursor {
		after = &cur
	}

	items, err := h.svc.Popular(r.Context(), viewer(r), after, limit)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	resp := page[communityDTO]{Items: toCommunityDTOs(items)}
	if len(items) == limit {
		last := items[len(items)-1]
		resp.NextCursor = encodeCursor(community.PopularCursor{Subscribers: last.SubscribersCount, ID: last.ID})
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *communityHandlers) search(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Search(r.Context(), r.URL.Query().Get("q"), viewer(r), 20)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page[communityDTO]{Items: toCommunityDTOs(items)})
}

func (h *communityHandlers) get(w http.ResponseWriter, r *http.Request) {
	h.respond(w, r, http.StatusOK)(h.svc.Get(r.Context(), chi.URLParam(r, "slug"), viewer(r)))
}

func (h *communityHandlers) create(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Slug        string `json:"slug"`
		Title       string `json:"title"`
		Description string `json:"description"`
		IsNSFW      bool   `json:"is_nsfw"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	h.respond(w, r, http.StatusCreated)(h.svc.Create(r.Context(), viewer(r), community.CreateInput{
		Slug:        req.Slug,
		Title:       req.Title,
		Description: req.Description,
		IsNSFW:      req.IsNSFW,
	}))
}

func (h *communityHandlers) update(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title       *string `json:"title"`
		Description *string `json:"description"`
		IsNSFW      *bool   `json:"is_nsfw"`
		// The whole list, in order; [] removes every rule.
		Rules *[]ruleDTO `json:"rules"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	in := community.UpdateInput{
		Title:       req.Title,
		Description: req.Description,
		IsNSFW:      req.IsNSFW,
	}
	if req.Rules != nil {
		rules := make([]community.Rule, len(*req.Rules))
		for i, r := range *req.Rules {
			rules[i] = community.Rule(r)
		}
		in.Rules = &rules
	}
	h.respond(w, r, http.StatusOK)(h.svc.Update(r.Context(), chi.URLParam(r, "slug"), viewer(r), in))
}

func (h *communityHandlers) subscribe(w http.ResponseWriter, r *http.Request) {
	h.respond(w, r, http.StatusOK)(h.svc.Subscribe(r.Context(), chi.URLParam(r, "slug"), viewer(r)))
}

func (h *communityHandlers) unsubscribe(w http.ResponseWriter, r *http.Request) {
	h.respond(w, r, http.StatusOK)(h.svc.Unsubscribe(r.Context(), chi.URLParam(r, "slug"), viewer(r)))
}

func (h *communityHandlers) subscriptions(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Subscriptions(r.Context(), viewer(r))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, page[communityDTO]{Items: toCommunityDTOs(items)})
}

// respond writes a single community or the mapped error.
func (h *communityHandlers) respond(w http.ResponseWriter, r *http.Request, status int) func(community.Community, error) {
	return func(c community.Community, err error) {
		if err != nil {
			h.fail(w, r, err)
			return
		}
		writeJSON(w, status, toCommunityDTO(c))
	}
}

func (h *communityHandlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	var verr *community.ValidationError
	switch {
	case errors.As(err, &verr):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", verr.Field, verr.Message)
	case errors.Is(err, community.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "community not found")
	case errors.Is(err, community.ErrSlugTaken):
		writeFieldError(w, http.StatusConflict, "slug_taken", "slug", "this name is already taken")
	case errors.Is(err, community.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", "only moderators can do this")
	case errors.Is(err, community.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many communities created today")
	default:
		internalError(w, r, h.log, err)
	}
}
