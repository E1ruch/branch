package httpapi

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"net/http"
	"net/url"
	"testing"
	"time"

	"vetka/internal/auth"
	"vetka/internal/community"
	"vetka/internal/post"
	"vetka/internal/testdb"
	"vetka/internal/user"
)

type allowAll struct{}

func (allowAll) Allow(context.Context, string, int, time.Duration) (bool, error) { return true, nil }

func TestPostsAPI(t *testing.T) {
	db := testdb.New(t)
	_, key, _ := ed25519.GenerateKey(nil)
	issuer := auth.NewIssuer(key, time.Hour)
	c := client{t, NewRouter(Deps{
		Logger: discard, RequestTimeout: 5 * time.Second,
		Auth:        auth.NewService(db, issuer, nil, nil, auth.Config{}, discard),
		Users:       user.NewStore(db),
		Communities: community.NewService(db),
		Posts:       post.NewService(db, allowAll{}),
	})}
	token := func(username string) string {
		tok, _, _ := issuer.Issue(testdb.CreateUser(t, db, username))
		return tok
	}
	author, reader := token("author"), token("reader")
	c.call("POST", "/v1/communities", author, map[string]any{"slug": "news", "title": "Новости"})
	c.call("PUT", "/v1/communities/news/subscription", reader, nil)

	if status, _ := c.call("POST", "/v1/communities/news/posts", "", map[string]any{"title": "x"}); status != http.StatusUnauthorized {
		t.Errorf("anonymous post: %d", status)
	}

	var ids []float64
	for i := range 3 {
		status, body := c.call("POST", "/v1/communities/news/posts", author, map[string]any{"title": fmt.Sprintf("Пост %d", i), "body": "текст"})
		if status != http.StatusCreated {
			t.Fatalf("create: %d %v", status, body)
		}
		ids = append(ids, body["id"].(float64))
	}
	if status, body := c.call("POST", "/v1/communities/news/posts", author, map[string]any{"title": ""}); status != http.StatusUnprocessableEntity || body["error"].(map[string]any)["field"] != "title" {
		t.Errorf("empty title: %d %v", status, body)
	}

	// Every feed pages through all three posts.
	for _, feed := range []struct{ path, token string }{
		{"/v1/feed/all?sort=new&limit=2", ""},
		{"/v1/feed/subscriptions?sort=hot&limit=2", reader},
		{"/v1/communities/news/posts?limit=2", ""},
	} {
		seen, path := 0, feed.path
		for range 5 {
			status, body := c.call("GET", path, feed.token, nil)
			if status != http.StatusOK {
				t.Fatalf("%s: %d %v", path, status, body)
			}
			seen += len(body["items"].([]any))
			next, _ := body["next_cursor"].(string)
			if next == "" {
				break
			}
			path = feed.path + "&cursor=" + url.QueryEscape(next)
		}
		if seen != 3 {
			t.Errorf("%s: saw %d posts, want 3", feed.path, seen)
		}
	}

	if status, _ := c.call("GET", "/v1/feed/subscriptions", "", nil); status != http.StatusUnauthorized {
		t.Errorf("anonymous subscriptions feed: %d", status)
	}
	if status, _ := c.call("GET", "/v1/feed/all?sort=top", "", nil); status != http.StatusBadRequest {
		t.Errorf("unknown sort: %d", status)
	}

	postPath := fmt.Sprintf("/v1/posts/%d", int64(ids[0]))
	status, body := c.call("GET", postPath, "", nil)
	if status != http.StatusOK || body["author"].(map[string]any)["username"] != "author" || body["body"] != "текст" {
		t.Errorf("get: %d %v", status, body)
	}
	if status, _ := c.call("PATCH", postPath, reader, map[string]any{"body": "взлом"}); status != http.StatusForbidden {
		t.Errorf("stranger edit: %d", status)
	}
	if status, body := c.call("PATCH", postPath, author, map[string]any{"body": "правка"}); status != http.StatusOK || body["body"] != "правка" || body["edited_at"] == nil {
		t.Errorf("edit: %d %v", status, body)
	}
	if status, _ := c.call("DELETE", postPath, author, nil); status != http.StatusNoContent {
		t.Errorf("delete: %d", status)
	}
	if status, _ := c.call("GET", postPath, "", nil); status != http.StatusNotFound {
		t.Errorf("deleted post: %d", status)
	}
	if status, _ := c.call("GET", "/v1/posts/abc", "", nil); status != http.StatusNotFound {
		t.Errorf("non-numeric id: %d", status)
	}
}
