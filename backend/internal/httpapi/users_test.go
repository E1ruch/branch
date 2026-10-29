package httpapi

import (
	"crypto/ed25519"
	"fmt"
	"net/http"
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

func TestProfileAPI(t *testing.T) {
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
	me, _, _ := issuer.Issue(testdb.CreateUser(t, db, "user_onboard"))
	other, _, _ := issuer.Issue(testdb.CreateUser(t, db, "taken_name"))

	status, body := c.call("GET", "/v1/me", me, nil)
	if status != http.StatusOK || body["username_changeable_at"] != nil {
		t.Fatalf("me: %d %v", status, body)
	}

	for name, want := range map[string]string{"ivan": "", "Taken_Name": "taken", "ab": "invalid", "admin": "invalid"} {
		_, body := c.call("GET", "/v1/usernames/"+name+"/availability", "", nil)
		if reason, _ := body["reason"].(string); reason != want || body["available"] != (want == "") {
			t.Errorf("availability %q: %v, want reason %q", name, body, want)
		}
	}

	status, body = c.call("PATCH", "/v1/me", me, map[string]any{"username": "ivan", "display_name": "Иван", "bio": "Привет"})
	if status != http.StatusOK || body["username"] != "ivan" || body["bio"] != "Привет" || body["username_changeable_at"] == nil {
		t.Fatalf("onboarding: %d %v", status, body)
	}
	if status, body := c.call("PATCH", "/v1/me", me, map[string]any{"username": "ivan_two"}); status != http.StatusConflict || errCode(body) != "username_change_too_soon" {
		t.Errorf("second rename: %d %v", status, body)
	}
	if status, body := c.call("PATCH", "/v1/me", other, map[string]any{"username": "IVAN"}); status != http.StatusConflict || errCode(body) != "username_taken" {
		t.Errorf("taken rename: %d %v", status, body)
	}

	c.call("POST", "/v1/communities", me, map[string]any{"slug": "news", "title": "Новости"})
	_, p := c.call("POST", "/v1/communities/news/posts", me, map[string]any{"title": "Мой пост"})
	c.call("POST", fmt.Sprintf("/v1/posts/%d/comments", int64(p["id"].(float64))), me, map[string]any{"body": "Мой коммент"})

	status, body = c.call("GET", "/v1/users/IVAN", "", nil)
	if status != http.StatusOK || body["display_name"] != "Иван" || body["username_changeable_at"] != nil {
		t.Errorf("public profile (must not expose owner-only fields): %d %v", status, body)
	}
	_, body = c.call("GET", "/v1/users/ivan/posts", "", nil)
	if items := body["items"].([]any); len(items) != 1 || items[0].(map[string]any)["title"] != "Мой пост" {
		t.Errorf("user posts: %v", body)
	}
	_, body = c.call("GET", "/v1/users/ivan/comments", "", nil)
	items := body["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["post"].(map[string]any)["title"] != "Мой пост" {
		t.Errorf("user comments: %v", body)
	}

	// Follows: a state, so a second PUT changes nothing; counters on both sides.
	for range 2 {
		if status, body := c.call("PUT", "/v1/users/ivan/follow", other, nil); status != http.StatusOK || body["is_following"] != true || body["followers_count"] != 1.0 {
			t.Fatalf("follow: %d %v", status, body)
		}
	}
	if _, body := c.call("GET", "/v1/users/ivan", other, nil); body["is_following"] != true || body["posts_count"] != 1.0 {
		t.Errorf("profile as follower: %v", body)
	}
	if _, body := c.call("GET", "/v1/users/ivan", "", nil); body["is_following"] != false {
		t.Errorf("profile signed out: %v", body)
	}
	if _, body := c.call("GET", "/v1/users/taken_name", "", nil); body["following_count"] != 1.0 {
		t.Errorf("follower's following_count: %v", body)
	}
	if status, body := c.call("PUT", "/v1/users/ivan/follow", me, nil); status != http.StatusUnprocessableEntity || errCode(body) != "cannot_follow_self" {
		t.Errorf("follow self: %d %v", status, body)
	}
	if status, _ := c.call("PUT", "/v1/users/ivan/follow", "", nil); status != http.StatusUnauthorized {
		t.Errorf("follow signed out: %d", status)
	}
	if status, body := c.call("DELETE", "/v1/users/ivan/follow", other, nil); status != http.StatusOK || body["is_following"] != false || body["followers_count"] != 0.0 {
		t.Errorf("unfollow: %d %v", status, body)
	}
	c.call("PUT", "/v1/users/ivan/follow", other, nil)

	// Lists: the latest follow first, each row with the viewer's own follow.
	third, _, _ := issuer.Issue(testdb.CreateUser(t, db, "third_one"))
	c.call("PUT", "/v1/users/ivan/follow", third, nil)
	c.call("PUT", "/v1/users/third_one/follow", me, nil)
	names := func(body map[string]any) (out []string) {
		for _, it := range body["items"].([]any) {
			out = append(out, it.(map[string]any)["username"].(string))
		}
		return out
	}
	_, body = c.call("GET", "/v1/users/ivan/followers", me, nil)
	if got := names(body); len(got) != 2 || got[0] != "third_one" || got[1] != "taken_name" {
		t.Errorf("followers: %v", got)
	}
	if first := body["items"].([]any)[0].(map[string]any); first["is_following"] != true {
		t.Errorf("followers row is_following for the viewer: %v", first)
	}
	_, body = c.call("GET", "/v1/users/ivan/followers?limit=1", "", nil)
	if got := names(body); len(got) != 1 || got[0] != "third_one" || body["next_cursor"] == nil {
		t.Fatalf("followers page 1: %v", body)
	}
	_, body = c.call("GET", "/v1/users/ivan/followers?limit=1&cursor="+body["next_cursor"].(string), "", nil)
	if got := names(body); len(got) != 1 || got[0] != "taken_name" {
		t.Errorf("followers page 2: %v", got)
	}
	_, body = c.call("GET", "/v1/users/ivan/following", "", nil)
	if got := names(body); len(got) != 1 || got[0] != "third_one" {
		t.Errorf("following: %v", got)
	}
	c.call("DELETE", "/v1/users/ivan/follow", third, nil)
	c.call("DELETE", "/v1/users/third_one/follow", me, nil)

	_, p2 := c.call("POST", "/v1/communities/news/posts", me, map[string]any{"title": "Второй"})
	c.call("DELETE", fmt.Sprintf("/v1/posts/%d", int64(p2["id"].(float64))), me, nil)
	if _, body := c.call("GET", "/v1/me", me, nil); body["posts_count"] != 1.0 {
		t.Errorf("posts_count after create and delete: %v", body["posts_count"])
	}

	if status, _ := c.call("DELETE", "/v1/me", me, nil); status != http.StatusNoContent {
		t.Errorf("delete: %d", status)
	}
	if _, body := c.call("GET", "/v1/users/taken_name", "", nil); body["following_count"] != 0.0 {
		t.Errorf("following_count after the followee left: %v", body)
	}
	if status, _ := c.call("GET", "/v1/me", me, nil); status != http.StatusUnauthorized {
		t.Errorf("me after delete: %d, want 401 so the app signs out", status)
	}
	if status, _ := c.call("GET", "/v1/users/ivan", "", nil); status != http.StatusNotFound {
		t.Errorf("profile after delete: %d", status)
	}
	_, body = c.call("GET", fmt.Sprintf("/v1/posts/%d", int64(p["id"].(float64))), "", nil)
	if body["author"] != nil {
		t.Errorf("post author after delete: %v", body["author"])
	}
}
