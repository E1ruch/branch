package httpapi

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"net/url"
	"testing"
	"time"

	"vetka/internal/auth"
	"vetka/internal/community"
	"vetka/internal/post"
	"vetka/internal/search"
	"vetka/internal/testdb"
	"vetka/internal/user"
)

func TestSearchAPI(t *testing.T) {
	db := testdb.New(t)
	_, key, _ := ed25519.GenerateKey(nil)
	issuer := auth.NewIssuer(key, time.Hour)
	c := client{t, NewRouter(Deps{
		Logger: discard, RequestTimeout: 5 * time.Second,
		Auth:        auth.NewService(db, issuer, nil, nil, auth.Config{}, discard),
		Users:       user.NewStore(db),
		Communities: community.NewService(db),
		Posts:       post.NewService(db, allowAll{}),
		Search:      search.NewService(db),
	})}
	tok, _, _ := issuer.Issue(testdb.CreateUser(t, db, "gamer"))
	c.call("POST", "/v1/communities", tok, map[string]any{"slug": "igry", "title": "Игры"})
	c.call("POST", "/v1/communities/igry/posts", tok, map[string]any{"title": "Лучшие игры года", "body": "Список"})

	q := url.QueryEscape("игры")
	status, body := c.call("GET", "/v1/search/posts?q="+q, "", nil)
	if items := body["items"].([]any); status != http.StatusOK || len(items) != 1 {
		t.Errorf("posts: %d %v", status, body)
	}
	status, body = c.call("GET", "/v1/search/users?q=game", "", nil)
	if items := body["items"].([]any); status != http.StatusOK || len(items) != 1 ||
		items[0].(map[string]any)["username"] != "gamer" {
		t.Errorf("users: %d %v", status, body)
	}

	if status, _ := c.call("POST", "/v1/search/queries", "", map[string]any{"query": "игры"}); status != http.StatusUnauthorized {
		t.Errorf("anonymous record: %d, want 401", status)
	}
	if status, _ := c.call("POST", "/v1/search/queries", tok, map[string]any{"query": "игры"}); status != http.StatusNoContent {
		t.Errorf("record: %d", status)
	}
	// Rate limited once the limiter says so.
	limited := client{t, NewRouter(Deps{
		Logger: discard, RequestTimeout: 5 * time.Second,
		Auth: auth.NewService(db, issuer, nil, nil, auth.Config{}, discard), Users: user.NewStore(db),
		Communities: community.NewService(db), Posts: post.NewService(db, allowAll{}), Search: search.NewService(db),
		SearchLimiter: denyAll{},
	})}
	if status, body := limited.call("GET", "/v1/search/users?q=game", "", nil); status != http.StatusTooManyRequests || errCode(body) != "rate_limited" {
		t.Errorf("limited: %d %v", status, body)
	}
	if status, _ := limited.call("GET", "/v1/search/popular", "", nil); status != http.StatusOK {
		t.Errorf("popular is not limited: %d", status)
	}

	status, body = c.call("GET", "/v1/search/popular", "", nil)
	if items := body["items"].([]any); status != http.StatusOK || len(items) != 1 || items[0] != "игры" {
		t.Errorf("popular (from communities): %d %v", status, body)
	}
}

type denyAll struct{}

func (denyAll) Allow(context.Context, string, int, time.Duration) (bool, error) { return false, nil }
