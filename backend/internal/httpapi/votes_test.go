package httpapi

import (
	"crypto/ed25519"
	"fmt"
	"net/http"
	"testing"
	"time"

	"vetka/internal/auth"
	"vetka/internal/community"
	"vetka/internal/post"
	"vetka/internal/testdb"
	"vetka/internal/user"
	"vetka/internal/vote"
)

func TestVotesAPI(t *testing.T) {
	db := testdb.New(t)
	_, key, _ := ed25519.GenerateKey(nil)
	issuer := auth.NewIssuer(key, time.Hour)
	c := client{t, NewRouter(Deps{
		Logger: discard, RequestTimeout: 5 * time.Second,
		Auth:        auth.NewService(db, issuer, nil, nil, auth.Config{}, discard),
		Users:       user.NewStore(db),
		Communities: community.NewService(db),
		Posts:       post.NewService(db, allowAll{}),
		Votes:       vote.NewService(db, allowAll{}),
	})}
	token := func(username string) string {
		tok, _, _ := issuer.Issue(testdb.CreateUser(t, db, username))
		return tok
	}
	author, voter := token("author"), token("voter")
	c.call("POST", "/v1/communities", author, map[string]any{"slug": "news", "title": "Новости"})
	_, created := c.call("POST", "/v1/communities/news/posts", author, map[string]any{"title": "Пост"})
	path := fmt.Sprintf("/v1/posts/%d/vote", int64(created["id"].(float64)))

	status, body := c.call("PUT", path, voter, map[string]any{"value": 1})
	if status != http.StatusOK || body["my_vote"] != 1.0 || body["score"] != 1.0 {
		t.Fatalf("upvote: %d %v", status, body)
	}

	// The viewer's vote shows up in feeds before the worker runs; the score
	// catches up after it.
	_, feed := c.call("GET", "/v1/feed/all", voter, nil)
	if p := feed["items"].([]any)[0].(map[string]any); p["my_vote"] != 1.0 || p["score"] != 0.0 {
		t.Errorf("feed before flush: my_vote=%v score=%v", p["my_vote"], p["score"])
	}
	if _, err := vote.Flush(t.Context(), db, 100); err != nil {
		t.Fatal(err)
	}
	_, feed = c.call("GET", "/v1/feed/all", "", nil)
	if p := feed["items"].([]any)[0].(map[string]any); p["my_vote"] != 0.0 || p["score"] != 1.0 {
		t.Errorf("anonymous feed after flush: my_vote=%v score=%v", p["my_vote"], p["score"])
	}

	tests := []struct {
		token  string
		body   any
		status int
	}{
		{"", map[string]any{"value": 1}, http.StatusUnauthorized},
		{voter, map[string]any{}, http.StatusUnprocessableEntity}, // missing value must not clear the vote
		{voter, map[string]any{"value": 5}, http.StatusUnprocessableEntity},
	}
	for _, tt := range tests {
		if status, body := c.call("PUT", path, tt.token, tt.body); status != tt.status {
			t.Errorf("%v: %d %v, want %d", tt.body, status, body, tt.status)
		}
	}
	if status, _ := c.call("PUT", "/v1/posts/999999/vote", voter, map[string]any{"value": 1}); status != http.StatusNotFound {
		t.Errorf("unknown post: %d", status)
	}
}
