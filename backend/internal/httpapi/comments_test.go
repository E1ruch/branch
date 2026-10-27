package httpapi

import (
	"crypto/ed25519"
	"fmt"
	"net/http"
	"net/url"
	"testing"
	"time"

	"vetka/internal/auth"
	"vetka/internal/comment"
	"vetka/internal/community"
	"vetka/internal/post"
	"vetka/internal/testdb"
	"vetka/internal/user"
	"vetka/internal/vote"
)

func TestCommentsAPI(t *testing.T) {
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
		Comments:    comment.NewService(db, allowAll{}),
	})}
	token := func(username string) string {
		tok, _, _ := issuer.Issue(testdb.CreateUser(t, db, username))
		return tok
	}
	author, reader := token("author"), token("reader")
	c.call("POST", "/v1/communities", author, map[string]any{"slug": "news", "title": "Новости"})
	_, p := c.call("POST", "/v1/communities/news/posts", author, map[string]any{"title": "Пост"})
	base := fmt.Sprintf("/v1/posts/%d/comments", int64(p["id"].(float64)))

	if status, _ := c.call("POST", base, "", map[string]any{"body": "x"}); status != http.StatusUnauthorized {
		t.Errorf("anonymous comment: %d", status)
	}
	status, top := c.call("POST", base, author, map[string]any{"body": "Первый"})
	if status != http.StatusCreated || top["depth"] != 0.0 {
		t.Fatalf("create: %d %v", status, top)
	}
	topID := int64(top["id"].(float64))
	for i := range 10 {
		if status, body := c.call("POST", base, reader, map[string]any{"body": fmt.Sprintf("ответ %d", i), "parent_id": topID}); status != http.StatusCreated {
			t.Fatalf("reply: %d %v", status, body)
		}
	}
	if status, body := c.call("POST", base, reader, map[string]any{"body": "x", "parent_id": 999999}); status != http.StatusUnprocessableEntity || errCode(body) != "parent_not_found" {
		t.Errorf("unknown parent: %d %v", status, body)
	}

	// 1 top comment + 8 replies + a "more" stub for the other 2.
	status, thread := c.call("GET", base+"?sort=new", reader, nil)
	items := thread["items"].([]any)
	if status != http.StatusOK || len(items) != 10 {
		t.Fatalf("thread: %d, %d items", status, len(items))
	}
	stub := items[9].(map[string]any)
	if stub["kind"] != "more" || stub["count"] != 2.0 || stub["parent_id"] != float64(topID) {
		t.Fatalf("stub: %v", stub)
	}
	morePath := fmt.Sprintf("/v1/comments/%d/replies?sort=new&cursor=%s", topID, url.QueryEscape(stub["cursor"].(string)))
	status, more := c.call("GET", morePath, reader, nil)
	if status != http.StatusOK || len(more["items"].([]any)) != 2 {
		t.Errorf("more: %d %v", status, more)
	}

	commentPath := fmt.Sprintf("/v1/comments/%d", topID)
	if status, body := c.call("PUT", commentPath+"/vote", reader, map[string]any{"value": 1}); status != http.StatusOK || body["score"] != 1.0 {
		t.Errorf("vote: %d %v", status, body)
	}
	if status, _ := c.call("PATCH", commentPath, reader, map[string]any{"body": "взлом"}); status != http.StatusForbidden {
		t.Errorf("stranger edit: %d", status)
	}
	if status, _ := c.call("DELETE", commentPath, author, nil); status != http.StatusNoContent {
		t.Errorf("delete: %d", status)
	}
	_, thread = c.call("GET", base, "", nil)
	tomb := thread["items"].([]any)[0].(map[string]any)["comment"].(map[string]any)
	if tomb["is_deleted"] != true || tomb["body"] != nil || tomb["author"] != nil {
		t.Errorf("tombstone: %v", tomb)
	}
	if status, _ := c.call("GET", "/v1/posts/999999/comments", "", nil); status != http.StatusNotFound {
		t.Errorf("unknown post: %d", status)
	}
}
