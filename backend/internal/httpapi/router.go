// Package httpapi is the HTTP layer: routing, middleware and handlers.
package httpapi

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"vetka/internal/auth"
	"vetka/internal/comment"
	"vetka/internal/community"
	"vetka/internal/post"
	"vetka/internal/search"
	"vetka/internal/user"
	"vetka/internal/vote"
)

type Deps struct {
	Logger         *slog.Logger
	RequestTimeout time.Duration
	Checks         map[string]Check

	Auth        *auth.Service
	Users       *user.Store
	Communities *community.Service
	Posts       *post.Service
	Votes       *vote.Service
	Comments    *comment.Service
	Search      *search.Service
	// Caps search requests; nil (tests) leaves them uncapped.
	SearchLimiter Limiter

	TelegramBot   string // bot username for the login widget; empty disables it
	TelegramToken string // signs fake logins
	TelegramFake  bool   // local development: a form instead of the real widget
	PublicBaseURL string // where the API is reachable from a browser
	AppScheme     string // the app's URL scheme for auth redirects
}

func NewRouter(d Deps) http.Handler {
	authH := &authHandlers{svc: d.Auth, log: d.Logger}
	commH := &communityHandlers{svc: d.Communities, log: d.Logger}
	postH := &postHandlers{svc: d.Posts, log: d.Logger}
	voteH := &voteHandlers{svc: d.Votes, log: d.Logger}
	commentH := &commentHandlers{svc: d.Comments, log: d.Logger}
	searchH := &searchHandlers{svc: d.Search, users: d.Users, posts: postH, log: d.Logger}
	searchLimit := limitSearch(d.SearchLimiter, d.Logger)
	userH := &userHandlers{users: d.Users, posts: postH, comments: d.Comments, log: d.Logger}
	tg := telegramPage{botUsername: d.TelegramBot, botToken: d.TelegramToken, fake: d.TelegramFake,
		publicBaseURL: d.PublicBaseURL, appScheme: d.AppScheme}

	r := chi.NewRouter()
	r.Use(middleware.RequestID, requestLogger(d.Logger), recoverer(d.Logger))

	r.NotFound(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
	})
	r.MethodNotAllowed(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	})

	r.Get("/healthz", healthz)
	r.Get("/readyz", readyz(d.Logger, d.Checks))

	// Browser pages for the Telegram web sign-in flow, outside the JSON API.
	r.Get("/auth/telegram", tg.page)
	r.Get("/auth/telegram/callback", tg.callback)
	r.Post("/auth/telegram/fake", tg.fakeSubmit)

	r.Route("/v1", func(r chi.Router) {
		r.Use(authenticate(d.Auth.VerifyAccessToken))

		// The timeout and gzip apply to plain request/response routes. The
		// WebSocket endpoint will be mounted next to this group, not inside it:
		// a long-lived connection must not be cut by the request timeout.
		r.Group(func(r chi.Router) {
			r.Use(middleware.Timeout(d.RequestTimeout))
			r.Use(middleware.Compress(5, "application/json"))

			r.Route("/auth", func(r chi.Router) {
				r.Post("/apple", authH.apple)
				r.Post("/telegram", authH.telegram)
				r.Post("/register", authH.register)
				r.Post("/login", authH.login)
				r.Post("/refresh", authH.refresh)
				r.Post("/logout", authH.logout)
			})

			r.Route("/me", func(r chi.Router) {
				r.Use(requireAuth)
				r.Get("/", userH.me)
				r.Patch("/", userH.updateMe)
				r.Delete("/", userH.deleteMe)
				r.Get("/subscriptions", commH.subscriptions)
			})

			r.Route("/users/{username}", func(r chi.Router) {
				r.Get("/", userH.profile)
				r.Get("/posts", userH.userPosts)
				r.Get("/comments", userH.userComments)
			})
			r.Get("/usernames/{username}/availability", userH.usernameAvailability)

			r.Get("/feed/all", postH.feedAll)
			r.With(requireAuth).Get("/feed/subscriptions", postH.feedSubscriptions)

			r.Route("/posts/{id}", func(r chi.Router) {
				r.Get("/", postH.get)
				r.Get("/story", postH.story)
				r.With(requireAuth).Patch("/", postH.edit)
				r.With(requireAuth).Delete("/", postH.delete)
				r.With(requireAuth).Put("/vote", voteH.votePost)
				r.Get("/comments", commentH.thread)
				r.With(requireAuth).Post("/comments", commentH.create)
			})

			r.Route("/comments/{id}", func(r chi.Router) {
				r.Get("/", commentH.get)
				r.Get("/replies", commentH.replies)
				r.With(requireAuth).Patch("/", commentH.edit)
				r.With(requireAuth).Delete("/", commentH.delete)
				r.With(requireAuth).Put("/vote", voteH.voteComment)
			})

			r.Route("/search", func(r chi.Router) {
				r.With(searchLimit).Get("/users", searchH.people)
				r.With(searchLimit).Get("/posts", searchH.postResults)
				r.Get("/popular", searchH.popular)
				r.With(requireAuth).Post("/queries", searchH.record)
			})

			r.Route("/communities", func(r chi.Router) {
				r.Get("/", commH.list)
				r.With(searchLimit).Get("/search", commH.search)
				r.With(requireAuth).Post("/", commH.create)
				r.Route("/{slug}", func(r chi.Router) {
					r.Get("/", commH.get)
					r.With(requireAuth).Patch("/", commH.update)
					// PUT/DELETE of a state, not a toggle: retries are safe.
					r.With(requireAuth).Put("/subscription", commH.subscribe)
					r.With(requireAuth).Delete("/subscription", commH.unsubscribe)
					r.Get("/posts", postH.feedCommunity)
					r.With(requireAuth).Post("/posts", postH.create)
				})
			})
		})
	})

	return r
}
