package httpapi

import (
	"crypto/ed25519"
	"net/http"
	"net/url"
	"testing"
	"time"

	"vetka/internal/auth"
	"vetka/internal/community"
	"vetka/internal/testdb"
	"vetka/internal/user"
)

func TestCommunitiesAPI(t *testing.T) {
	db := testdb.New(t)
	_, key, _ := ed25519.GenerateKey(nil)
	issuer := auth.NewIssuer(key, time.Hour)
	svc := auth.NewService(db, issuer, nil, nil, auth.Config{}, discard)
	c := client{t, NewRouter(Deps{
		Logger: discard, RequestTimeout: 5 * time.Second,
		Auth: svc, Users: user.NewStore(db), Communities: community.NewService(db),
	})}
	token := func(username string) string {
		tok, _, err := issuer.Issue(testdb.CreateUser(t, db, username))
		if err != nil {
			t.Fatal(err)
		}
		return tok
	}
	owner, reader := token("owner"), token("reader")

	if status, _ := c.call("POST", "/v1/communities", "", map[string]any{"slug": "news", "title": "Новости"}); status != http.StatusUnauthorized {
		t.Errorf("anonymous create: %d, want 401", status)
	}

	status, body := c.call("POST", "/v1/communities", owner, map[string]any{"slug": "news", "title": "Новости"})
	if status != http.StatusCreated || body["viewer_role"] != "owner" || body["subscribers_count"] != 1.0 {
		t.Fatalf("create: %d %v", status, body)
	}

	status, body = c.call("POST", "/v1/communities", owner, map[string]any{"slug": "x", "title": "x"})
	if e := body["error"].(map[string]any); status != http.StatusUnprocessableEntity || e["field"] != "slug" {
		t.Errorf("invalid slug: %d %v", status, body)
	}
	status, body = c.call("POST", "/v1/communities", owner, map[string]any{"slug": "NEWS", "title": "x"})
	if status != http.StatusConflict || errCode(body) != "slug_taken" {
		t.Errorf("taken slug: %d %v", status, body)
	}

	status, body = c.call("PUT", "/v1/communities/news/subscription", reader, nil)
	if status != http.StatusOK || body["is_subscribed"] != true || body["subscribers_count"] != 2.0 {
		t.Errorf("subscribe: %d %v", status, body)
	}
	status, body = c.call("GET", "/v1/me/subscriptions", reader, nil)
	if items := body["items"].([]any); status != http.StatusOK || len(items) != 1 {
		t.Errorf("subscriptions: %d %v", status, body)
	}
	status, body = c.call("DELETE", "/v1/communities/news/subscription", reader, nil)
	if status != http.StatusOK || body["is_subscribed"] != false || body["subscribers_count"] != 1.0 {
		t.Errorf("unsubscribe: %d %v", status, body)
	}

	if status, body := c.call("PATCH", "/v1/communities/news", reader, map[string]any{"title": "Захват"}); status != http.StatusForbidden {
		t.Errorf("non-moderator update: %d %v", status, body)
	}
	status, body = c.call("PATCH", "/v1/communities/news", owner,
		map[string]any{"rules": []map[string]any{{"title": "Без спама", "body": "Реклама — бан"}}})
	if rules, _ := body["rules"].([]any); status != http.StatusOK || len(rules) != 1 {
		t.Errorf("set rules: %d %v", status, body)
	}
	status, body = c.call("GET", "/v1/communities/news", "", nil)
	if rules, _ := body["rules"].([]any); status != http.StatusOK || len(rules) != 1 ||
		rules[0].(map[string]any)["title"] != "Без спама" {
		t.Errorf("get rules: %d %v", status, body)
	}
	status, body = c.call("PATCH", "/v1/communities/news", owner, map[string]any{"rules": []map[string]any{{"title": ""}}})
	if status != http.StatusUnprocessableEntity || body["error"].(map[string]any)["field"] != "rules" {
		t.Errorf("invalid rule: %d %v", status, body)
	}
	status, body = c.call("GET", "/v1/communities", "", nil)
	if _, has := body["items"].([]any)[0].(map[string]any)["rules"]; status != http.StatusOK || has {
		t.Errorf("list carries rules: %d %v", status, body)
	}

	if status, _ := c.call("GET", "/v1/communities/nope", "", nil); status != http.StatusNotFound {
		t.Errorf("unknown community: %d", status)
	}

	// Pagination: two more communities, pages of 2.
	c.call("POST", "/v1/communities", owner, map[string]any{"slug": "games", "title": "Игры"})
	c.call("POST", "/v1/communities", owner, map[string]any{"slug": "music", "title": "Музыка"})
	seen := map[string]bool{}
	path := "/v1/communities?limit=2"
	for range 5 {
		status, body = c.call("GET", path, "", nil)
		if status != http.StatusOK {
			t.Fatalf("list: %d %v", status, body)
		}
		for _, it := range body["items"].([]any) {
			seen[it.(map[string]any)["slug"].(string)] = true
		}
		next, _ := body["next_cursor"].(string)
		if next == "" {
			break
		}
		path = "/v1/communities?limit=2&cursor=" + url.QueryEscape(next)
	}
	if len(seen) != 3 {
		t.Errorf("paginated list saw %v, want 3 communities", seen)
	}

	if status, _ := c.call("GET", "/v1/communities?cursor=garbage", "", nil); status != http.StatusBadRequest {
		t.Errorf("bad cursor: %d, want 400", status)
	}
	if status, _ := c.call("GET", "/v1/communities?limit=1000", "", nil); status != http.StatusBadRequest {
		t.Errorf("huge limit: %d, want 400", status)
	}

	status, body = c.call("GET", "/v1/communities/search?q="+url.QueryEscape("муз"), "", nil)
	if items := body["items"].([]any); status != http.StatusOK || len(items) != 1 {
		t.Errorf("search: %d %v", status, body)
	}
}
