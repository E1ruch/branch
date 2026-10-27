package post

import (
	"context"
	"errors"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/ranking"
	"vetka/internal/testdb"
)

// countingLimiter allows `limit` events per key and forgets windows.
type countingLimiter struct {
	mu     sync.Mutex
	counts map[string]int
}

func (l *countingLimiter) Allow(_ context.Context, key string, limit int, _ time.Duration) (bool, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.counts[key]++
	return l.counts[key] <= limit, nil
}

type env struct {
	svc *Service
	db  *pgxpool.Pool
	ctx context.Context
}

func newEnv(t *testing.T) env {
	t.Helper()
	db := testdb.New(t)
	return env{svc: NewService(db, &countingLimiter{counts: map[string]int{}}), db: db, ctx: context.Background()}
}

func (e env) community(t *testing.T, slug string, nsfw bool) int64 {
	t.Helper()
	var id int64
	if err := e.db.QueryRow(e.ctx,
		`INSERT INTO communities (slug, title, is_nsfw) VALUES ($1, $2, $3) RETURNING id`,
		slug, "Сообщество "+slug, nsfw).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

// insertPost bypasses the service to pin hot_rank, as votes would.
func (e env) insertPost(t *testing.T, communityID, authorID int64, title string, rank float64, nsfw bool) int64 {
	t.Helper()
	var id int64
	if err := e.db.QueryRow(e.ctx, `
		INSERT INTO posts (community_id, author_id, title, hot_rank, is_nsfw)
		VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		communityID, authorID, title, rank, nsfw).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestCreate(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	e.community(t, "news", false)
	e.community(t, "adult", true)

	p, err := e.svc.Create(e.ctx, author, "NEWS", CreateInput{Title: "  Заголовок  ", Body: "Текст"})
	if err != nil {
		t.Fatal(err)
	}
	if p.Title != "Заголовок" || p.Body != "Текст" || p.Community.Slug != "news" || p.Author == nil || p.Author.Username != "author" {
		t.Errorf("created = %+v", p)
	}
	if want := ranking.Hot(0, 0, p.CreatedAt); math.Abs(p.HotRank-want) > 1e-6 {
		t.Errorf("hot_rank = %v, want ranking.Hot = %v", p.HotRank, want)
	}

	nsfw, err := e.svc.Create(e.ctx, author, "adult", CreateInput{Title: "x"})
	if err != nil || !nsfw.IsNSFW {
		t.Errorf("post in NSFW community must be NSFW: %+v, %v", nsfw, err)
	}

	if _, err := e.svc.Create(e.ctx, author, "nope", CreateInput{Title: "x"}); !errors.Is(err, ErrCommunityNotFound) {
		t.Errorf("unknown community: %v", err)
	}
	var verr *ValidationError
	if _, err := e.svc.Create(e.ctx, author, "news", CreateInput{Title: "   "}); !errors.As(err, &verr) || verr.Field != "title" {
		t.Errorf("empty title: %v", err)
	}
	if _, err := e.svc.Create(e.ctx, author, "news", CreateInput{Title: "x", Body: strings.Repeat("я", maxBody+1)}); !errors.As(err, &verr) || verr.Field != "body" {
		t.Errorf("long body: %v", err)
	}
}

func TestCreateRateLimit(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	e.community(t, "news", false)
	for range postsPerHour {
		if _, err := e.svc.Create(e.ctx, author, "news", CreateInput{Title: "x"}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.svc.Create(e.ctx, author, "news", CreateInput{Title: "x"}); !errors.Is(err, ErrRateLimited) {
		t.Errorf("err = %v, want ErrRateLimited", err)
	}
}

func TestEditAndDelete(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	stranger := testdb.CreateUser(t, e.db, "stranger")
	e.community(t, "news", false)
	p, _ := e.svc.Create(e.ctx, author, "news", CreateInput{Title: "Заголовок", Body: "старый"})

	edited, err := e.svc.Edit(e.ctx, p.ID, author, "новый")
	if err != nil || edited.Body != "новый" || edited.EditedAt == nil || edited.Title != "Заголовок" {
		t.Errorf("edit: %+v, %v", edited, err)
	}
	if _, err := e.svc.Edit(e.ctx, p.ID, stranger, "взлом"); !errors.Is(err, ErrForbidden) {
		t.Errorf("stranger edit: %v", err)
	}
	if err := e.svc.Delete(e.ctx, p.ID, stranger); !errors.Is(err, ErrForbidden) {
		t.Errorf("stranger delete: %v", err)
	}

	for range 2 { // retry-safe
		if err := e.svc.Delete(e.ctx, p.ID, author); err != nil {
			t.Fatalf("delete: %v", err)
		}
	}
	if _, err := e.svc.Get(e.ctx, p.ID, 0); !errors.Is(err, ErrNotFound) {
		t.Errorf("deleted post is still visible: %v", err)
	}
	if _, err := e.svc.Edit(e.ctx, p.ID, author, "x"); !errors.Is(err, ErrNotFound) {
		t.Errorf("edit deleted: %v", err)
	}
	if err := e.svc.Delete(e.ctx, 999999, author); !errors.Is(err, ErrNotFound) {
		t.Errorf("delete unknown: %v", err)
	}
}

func TestDeletedAuthorIsHidden(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	e.community(t, "news", false)
	p, _ := e.svc.Create(e.ctx, author, "news", CreateInput{Title: "x"})
	e.db.Exec(e.ctx, `UPDATE users SET deleted_at = now() WHERE id = $1`, author)

	got, err := e.svc.Get(e.ctx, p.ID, 0)
	if err != nil || got.Author != nil {
		t.Errorf("author of a deleted account must be nil: %+v, %v", got.Author, err)
	}
}

// pageAll walks a feed in pages of 2 and returns titles in order.
func pageAll(t *testing.T, fetch func(after *Cursor) ([]Post, error)) []string {
	t.Helper()
	var titles []string
	var after *Cursor
	for range 20 {
		items, err := fetch(after)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range items {
			titles = append(titles, p.Title)
		}
		if len(items) < 2 {
			return titles
		}
		c := CursorAfter(items[len(items)-1])
		after = &c
	}
	t.Fatal("feed did not end")
	return nil
}

func TestFeeds(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	reader := testdb.CreateUser(t, e.db, "reader")
	cats := e.community(t, "cats", false)
	dogs := e.community(t, "dogs", false)
	adult := e.community(t, "adult", true)
	for _, c := range []int64{cats, adult} {
		e.db.Exec(e.ctx, `INSERT INTO community_members (user_id, community_id) VALUES ($1, $2)`, reader, c)
	}

	// Insertion order = id order = "new" order (reversed).
	e.insertPost(t, cats, author, "cats-1", 10, false)
	e.insertPost(t, dogs, author, "dogs-1", 30, false)
	e.insertPost(t, cats, author, "cats-2", 20, false)
	e.insertPost(t, adult, author, "adult-1", 25, true)
	e.insertPost(t, cats, author, "cats-tie", 20, false) // same rank as cats-2: id breaks the tie
	gone := e.insertPost(t, dogs, author, "dogs-deleted", 99, false)
	e.db.Exec(e.ctx, `UPDATE posts SET deleted_at = now() WHERE id = $1`, gone)

	feed := func(name string, sort Sort, fn func(FeedQuery) ([]Post, error)) string {
		return strings.Join(pageAll(t, func(after *Cursor) ([]Post, error) {
			return fn(FeedQuery{Sort: sort, After: after, Limit: 2})
		}), " ")
	}
	all := func(q FeedQuery) ([]Post, error) { return e.svc.FeedAll(e.ctx, q) }
	subs := func(q FeedQuery) ([]Post, error) { return e.svc.FeedSubscriptions(e.ctx, reader, q) }
	catsFeed := func(q FeedQuery) ([]Post, error) { return e.svc.FeedCommunity(e.ctx, "cats", q) }

	tests := []struct {
		name string
		got  string
		want string
	}{
		{"all/hot: no NSFW, no deleted, tie by id", feed("all", SortHot, all), "dogs-1 cats-tie cats-2 cats-1"},
		{"all/new", feed("all", SortNew, all), "cats-tie cats-2 dogs-1 cats-1"},
		{"subscriptions/hot: merged, NSFW opted in", feed("subs", SortHot, subs), "adult-1 cats-tie cats-2 cats-1"},
		{"subscriptions/new", feed("subs", SortNew, subs), "cats-tie adult-1 cats-2 cats-1"},
		{"community/hot", feed("cats", SortHot, catsFeed), "cats-tie cats-2 cats-1"},
	}
	for _, tt := range tests {
		if tt.got != tt.want {
			t.Errorf("%s:\n got  %s\n want %s", tt.name, tt.got, tt.want)
		}
	}

	if _, err := e.svc.FeedCommunity(e.ctx, "nope", FeedQuery{Sort: SortHot, Limit: 2}); !errors.Is(err, ErrCommunityNotFound) {
		t.Errorf("unknown community: %v", err)
	}
	if items, err := e.svc.FeedSubscriptions(e.ctx, author, FeedQuery{Sort: SortHot, Limit: 2}); err != nil || len(items) != 0 {
		t.Errorf("no subscriptions: %d items, %v", len(items), err)
	}
}

func TestFeedShowsPreviewAndPostShowsFullBody(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	e.community(t, "news", false)
	long := strings.Repeat("ё", previewLen+50)
	p, _ := e.svc.Create(e.ctx, author, "news", CreateInput{Title: "long", Body: long})
	e.svc.Create(e.ctx, author, "news", CreateInput{Title: "short", Body: "коротко"})

	items, err := e.svc.FeedAll(e.ctx, FeedQuery{Sort: SortNew, Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	byTitle := map[string]Post{}
	for _, it := range items {
		byTitle[it.Title] = it
	}
	if lp := byTitle["long"]; !lp.BodyTruncated || len([]rune(lp.Body)) != previewLen {
		t.Errorf("long post in feed: truncated=%v len=%d", lp.BodyTruncated, len([]rune(lp.Body)))
	}
	if sp := byTitle["short"]; sp.BodyTruncated || sp.Body != "коротко" {
		t.Errorf("short post in feed: %+v", sp)
	}

	full, err := e.svc.Get(e.ctx, p.ID, 0)
	if err != nil || full.BodyTruncated || full.Body != long {
		t.Errorf("full post: truncated=%v len=%d, %v", full.BodyTruncated, len([]rune(full.Body)), err)
	}
}
