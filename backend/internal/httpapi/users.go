package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"vetka/internal/comment"
	"vetka/internal/post"
	"vetka/internal/user"
)

type userHandlers struct {
	users    *user.Store
	posts    *postHandlers // a user's posts are a feed like any other
	comments *comment.Service
	log      *slog.Logger
}

// meDTO is the signed-in user's own profile: the public one plus what only
// the owner needs.
type meDTO struct {
	userDTO
	// When a new username can be picked; null means now (always true right
	// after sign-up, so onboarding can offer it).
	UsernameChangeableAt *time.Time `json:"username_changeable_at"`
}

func toMeDTO(u user.User) meDTO {
	return meDTO{userDTO: toUserDTO(u), UsernameChangeableAt: u.UsernameChangeableAt}
}

type authoredCommentDTO struct {
	commentDTO
	Post struct {
		ID            int64  `json:"id"`
		Title         string `json:"title"`
		CommunitySlug string `json:"community_slug"`
	} `json:"post"`
}

func (h *userHandlers) me(w http.ResponseWriter, r *http.Request) {
	u, err := h.users.Get(r.Context(), viewer(r))
	if errors.Is(err, user.ErrNotFound) {
		// The token outlived the account (deleted within the access TTL):
		// 401 makes the app sign out instead of showing an empty profile.
		writeError(w, http.StatusUnauthorized, "unauthorized", "account not found")
		return
	}
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toMeDTO(u))
}

// updateMe: PATCH /v1/me {"username"?, "display_name"?, "bio"?}. Omitted
// fields stay; an empty display name or bio clears it.
func (h *userHandlers) updateMe(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username    *string `json:"username"`
		DisplayName *string `json:"display_name"`
		Bio         *string `json:"bio"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	u, err := h.users.Update(r.Context(), viewer(r), user.UpdateInput{
		Username:    req.Username,
		DisplayName: req.DisplayName,
		Bio:         req.Bio,
	})
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toMeDTO(u))
}

// deleteMe: DELETE /v1/me. The app signs out right after; the access token
// still verifies until it expires, but every user read now 404s.
func (h *userHandlers) deleteMe(w http.ResponseWriter, r *http.Request) {
	if err := h.users.Delete(r.Context(), viewer(r)); err != nil {
		h.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// profileDTO is someone's profile as the viewer sees it.
type profileDTO struct {
	userDTO
	IsFollowing bool `json:"is_following"`
}

func (h *userHandlers) profile(w http.ResponseWriter, r *http.Request) {
	u, err := h.users.GetByUsername(r.Context(), chi.URLParam(r, "username"))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	h.writeProfile(w, r, u)
}

// follow: PUT /v1/users/{username}/follow. A state, not a toggle.
func (h *userHandlers) follow(w http.ResponseWriter, r *http.Request) {
	u, err := h.users.Follow(r.Context(), viewer(r), chi.URLParam(r, "username"))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, profileDTO{userDTO: toUserDTO(u), IsFollowing: true})
}

// unfollow: DELETE /v1/users/{username}/follow.
func (h *userHandlers) unfollow(w http.ResponseWriter, r *http.Request) {
	u, err := h.users.Unfollow(r.Context(), viewer(r), chi.URLParam(r, "username"))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, profileDTO{userDTO: toUserDTO(u), IsFollowing: false})
}

// Follow limits: the app sends only the final state of a burst of taps, so
// a person stays far below these; a script mass-following or flapping a
// follow on someone popular (every change rewrites their counter row) does not.
const (
	followsPerMinute = 60
	followsPerDay    = 400
)

// limitFollows caps follow changes per account. A broken limiter lets
// them through: following is not worth an outage.
func limitFollows(l Limiter, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		if l == nil {
			return next
		}
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := "follow:user:" + strconv.FormatInt(viewer(r), 10)
			for _, window := range []struct {
				limit  int
				period time.Duration
				name   string
			}{{followsPerMinute, time.Minute, ":m"}, {followsPerDay, 24 * time.Hour, ":d"}} {
				ok, err := l.Allow(r.Context(), key+window.name, window.limit, window.period)
				if err != nil {
					log.WarnContext(r.Context(), "follow limiter failed", slog.Any("err", err))
					break
				}
				if !ok {
					writeError(w, http.StatusTooManyRequests, "rate_limited", "too many follows, try again later")
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// followers: GET /v1/users/{username}/followers, the latest first.
func (h *userHandlers) followers(w http.ResponseWriter, r *http.Request) {
	h.followList(w, r, h.users.Followers)
}

// following: GET /v1/users/{username}/following, the latest first.
func (h *userHandlers) following(w http.ResponseWriter, r *http.Request) {
	h.followList(w, r, h.users.Following)
}

type followLister func(ctx context.Context, userID, viewer int64, after *user.FollowCursor, limit int) ([]user.Listed, error)

func (h *userHandlers) followList(w http.ResponseWriter, r *http.Request, list followLister) {
	u, err := h.users.GetByUsername(r.Context(), chi.URLParam(r, "username"))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	limit, err := parseLimit(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var cur user.FollowCursor
	has, err := decodeCursor(r, &cur)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var after *user.FollowCursor
	if has {
		after = &cur
	}
	items, err := list(r.Context(), u.ID, viewer(r), after, limit)
	if err != nil {
		internalError(w, r, h.log, err)
		return
	}
	resp := page[profileDTO]{Items: make([]profileDTO, len(items))}
	for i, l := range items {
		resp.Items[i] = profileDTO{userDTO: toUserDTO(l.User), IsFollowing: l.IsFollowing}
	}
	if len(items) == limit {
		last := items[len(items)-1]
		resp.NextCursor = encodeCursor(user.FollowCursor{At: last.FollowedAt, ID: last.ID})
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *userHandlers) writeProfile(w http.ResponseWriter, r *http.Request, u user.User) {
	following, err := h.users.IsFollowing(r.Context(), viewer(r), u.ID)
	if err != nil {
		internalError(w, r, h.log, err)
		return
	}
	writeJSON(w, http.StatusOK, profileDTO{userDTO: toUserDTO(u), IsFollowing: following})
}

func (h *userHandlers) userPosts(w http.ResponseWriter, r *http.Request) {
	u, err := h.users.GetByUsername(r.Context(), chi.URLParam(r, "username"))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	q, ok := feedQuery(w, r)
	if !ok {
		return
	}
	q.Sort = post.SortNew
	items, err := h.posts.svc.ByAuthor(r.Context(), u.ID, q)
	h.posts.writeFeed(w, r, q, items, err)
}

func (h *userHandlers) userComments(w http.ResponseWriter, r *http.Request) {
	u, err := h.users.GetByUsername(r.Context(), chi.URLParam(r, "username"))
	if err != nil {
		h.fail(w, r, err)
		return
	}
	limit, err := parseLimit(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var cur comment.Cursor
	has, err := decodeCursor(r, &cur)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var after *comment.Cursor
	if has {
		after = &cur
	}

	items, err := h.comments.ByAuthor(r.Context(), u.ID, viewer(r), after, limit)
	if err != nil {
		internalError(w, r, h.log, err)
		return
	}
	resp := page[authoredCommentDTO]{Items: make([]authoredCommentDTO, len(items))}
	for i, a := range items {
		dto := authoredCommentDTO{commentDTO: toCommentDTO(a.Comment)}
		dto.Post.ID, dto.Post.Title, dto.Post.CommunitySlug = a.Post.ID, a.Post.Title, a.Post.CommunitySlug
		resp.Items[i] = dto
	}
	if len(items) == limit {
		resp.NextCursor = encodeCursor(comment.Cursor{ID: items[len(items)-1].ID})
	}
	writeJSON(w, http.StatusOK, resp)
}

// usernameAvailability: GET /v1/usernames/{username}/availability, for the
// live check under the onboarding text field.
func (h *userHandlers) usernameAvailability(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "username")
	resp := struct {
		Username  string `json:"username"`
		Available bool   `json:"available"`
		Reason    string `json:"reason,omitempty"` // invalid | taken
		Message   string `json:"message,omitempty"`
	}{Username: name}

	err := h.users.UsernameAvailable(r.Context(), name)
	var verr *user.ValidationError
	switch {
	case err == nil:
		resp.Available = true
	case errors.As(err, &verr):
		resp.Reason, resp.Message = "invalid", verr.Message
	case errors.Is(err, user.ErrUsernameTaken):
		resp.Reason = "taken"
	default:
		internalError(w, r, h.log, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *userHandlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	var verr *user.ValidationError
	switch {
	case errors.As(err, &verr):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", verr.Field, verr.Message)
	case errors.Is(err, user.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "user not found")
	case errors.Is(err, user.ErrUsernameTaken):
		writeFieldError(w, http.StatusConflict, "username_taken", "username", "this username is taken")
	case errors.Is(err, user.ErrFollowSelf):
		writeError(w, http.StatusUnprocessableEntity, "cannot_follow_self", "you cannot follow yourself")
	case errors.Is(err, user.ErrUsernameChangeTooSoon):
		writeFieldError(w, http.StatusConflict, "username_change_too_soon", "username", "username can be changed once in 30 days")
	default:
		internalError(w, r, h.log, err)
	}
}
