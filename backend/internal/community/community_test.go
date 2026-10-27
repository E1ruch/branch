package community

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/testdb"
)

type env struct {
	svc *Service
	db  *pgxpool.Pool
	ctx context.Context
}

func newEnv(t *testing.T) env {
	t.Helper()
	db := testdb.New(t)
	return env{svc: NewService(db), db: db, ctx: context.Background()}
}

func (e env) create(t *testing.T, owner int64, slug, title string) Community {
	t.Helper()
	c, err := e.svc.Create(e.ctx, owner, CreateInput{Slug: slug, Title: title})
	if err != nil {
		t.Fatalf("create %s: %v", slug, err)
	}
	return c
}

func TestCreateMakesOwnerAndFirstSubscriber(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")

	c, err := e.svc.Create(e.ctx, owner, CreateInput{Slug: "Kotiki", Title: "  Котики  ", Description: "Только котики"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Title != "Котики" || c.SubscribersCount != 1 || !c.IsSubscribed || c.ViewerRole == nil || *c.ViewerRole != "owner" {
		t.Errorf("created = %+v", c)
	}

	anon, err := e.svc.Get(e.ctx, "kotiki", 0) // slugs are case-insensitive
	if err != nil {
		t.Fatal(err)
	}
	if anon.IsSubscribed || anon.ViewerRole != nil {
		t.Errorf("anonymous view leaks viewer fields: %+v", anon)
	}
}

func TestCreateValidation(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	e.create(t, owner, "taken", "Taken")

	tests := []struct {
		in    CreateInput
		field string
		err   error
	}{
		{CreateInput{Slug: "ab", Title: "x"}, "slug", nil},
		{CreateInput{Slug: "котики", Title: "x"}, "slug", nil},
		{CreateInput{Slug: "Admin", Title: "x"}, "slug", nil},
		{CreateInput{Slug: "good_one", Title: "   "}, "title", nil},
		{CreateInput{Slug: "good_one", Title: strings.Repeat("я", 65)}, "title", nil},
		{CreateInput{Slug: "good_one", Title: "x", Description: strings.Repeat("я", 1001)}, "description", nil},
		{CreateInput{Slug: "TAKEN", Title: "x"}, "", ErrSlugTaken},
	}
	for _, tt := range tests {
		t.Run(tt.in.Slug+"/"+tt.field, func(t *testing.T) {
			_, err := e.svc.Create(e.ctx, owner, tt.in)
			if tt.err != nil {
				if !errors.Is(err, tt.err) {
					t.Errorf("err = %v, want %v", err, tt.err)
				}
				return
			}
			var verr *ValidationError
			if !errors.As(err, &verr) || verr.Field != tt.field {
				t.Errorf("err = %v, want validation error on %q", err, tt.field)
			}
		})
	}
}

func TestCreateRateLimit(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	for i := range maxCreatedPerDay {
		e.create(t, owner, fmt.Sprintf("c%03d", i), "x")
	}
	if _, err := e.svc.Create(e.ctx, owner, CreateInput{Slug: "one_more", Title: "x"}); !errors.Is(err, ErrRateLimited) {
		t.Errorf("err = %v, want ErrRateLimited", err)
	}
}

func TestSubscribeIsIdempotent(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	reader := testdb.CreateUser(t, e.db, "reader")
	e.create(t, owner, "news", "Новости")

	for range 2 {
		c, err := e.svc.Subscribe(e.ctx, "news", reader)
		if err != nil || !c.IsSubscribed || c.SubscribersCount != 2 {
			t.Fatalf("subscribe: %+v, %v", c, err)
		}
	}
	for range 2 {
		c, err := e.svc.Unsubscribe(e.ctx, "news", reader)
		if err != nil || c.IsSubscribed || c.SubscribersCount != 1 {
			t.Fatalf("unsubscribe: %+v, %v", c, err)
		}
	}
	if _, err := e.svc.Subscribe(e.ctx, "nope", reader); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown community: err = %v, want ErrNotFound", err)
	}
}

func TestOwnerCanUnsubscribeAndStayOwner(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	e.create(t, owner, "news", "Новости")

	c, err := e.svc.Unsubscribe(e.ctx, "news", owner)
	if err != nil || c.IsSubscribed || c.SubscribersCount != 0 || c.ViewerRole == nil || *c.ViewerRole != "owner" {
		t.Errorf("after unsubscribe: %+v, %v", c, err)
	}
	if _, err := e.svc.Update(e.ctx, "news", owner, UpdateInput{Description: new("still mine")}); err != nil {
		t.Errorf("owner lost moderation rights: %v", err)
	}
}

func TestUpdate(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	stranger := testdb.CreateUser(t, e.db, "stranger")
	e.create(t, owner, "news", "Новости")

	c, err := e.svc.Update(e.ctx, "news", owner, UpdateInput{Description: new("Свежее"), IsNSFW: new(true)})
	if err != nil || c.Title != "Новости" || c.Description != "Свежее" || !c.IsNSFW {
		t.Errorf("partial update: %+v, %v", c, err)
	}
	if _, err := e.svc.Update(e.ctx, "news", stranger, UpdateInput{Title: new("Захват")}); !errors.Is(err, ErrForbidden) {
		t.Errorf("stranger: err = %v, want ErrForbidden", err)
	}
	if _, err := e.svc.Update(e.ctx, "nope", owner, UpdateInput{Title: new("x")}); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown: err = %v, want ErrNotFound", err)
	}
	var verr *ValidationError
	if _, err := e.svc.Update(e.ctx, "news", owner, UpdateInput{Title: new("")}); !errors.As(err, &verr) {
		t.Errorf("empty title: err = %v, want ValidationError", err)
	}
}

func TestPopularPaginatesWithoutGapsOrDuplicates(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	readers := []int64{
		testdb.CreateUser(t, e.db, "reader1"),
		testdb.CreateUser(t, e.db, "reader2"),
		testdb.CreateUser(t, e.db, "reader3"),
	}
	// Bypass the per-user creation limit: insert directly.
	slugs := []string{"aaa", "bbb", "ccc", "ddd", "eee"}
	for _, s := range slugs {
		if _, err := e.db.Exec(e.ctx, `INSERT INTO communities (slug, title, created_by) VALUES ($1::text, $1::text, $2)`, s, owner); err != nil {
			t.Fatal(err)
		}
	}
	// Subscribers: ccc=3, aaa=2, bbb=eee=ddd=0 (ties broken by id desc).
	for _, r := range readers {
		e.svc.Subscribe(e.ctx, "ccc", r)
	}
	e.svc.Subscribe(e.ctx, "aaa", readers[0])
	e.svc.Subscribe(e.ctx, "aaa", readers[1])
	e.db.Exec(e.ctx, `INSERT INTO communities (slug, title, is_nsfw) VALUES ('nsfw_one', 'x', true)`)

	var got []string
	var after *PopularCursor
	for page := 0; page < 10; page++ {
		items, err := e.svc.Popular(e.ctx, readers[0], after, 2)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range items {
			got = append(got, c.Slug)
		}
		if len(items) < 2 {
			break
		}
		last := items[len(items)-1]
		after = &PopularCursor{Subscribers: last.SubscribersCount, ID: last.ID}
	}

	want := "ccc aaa eee ddd bbb"
	if strings.Join(got, " ") != want {
		t.Errorf("order = %v, want %s", got, want)
	}
}

func TestSearch(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	for _, c := range [][2]string{
		{"cats", "Котики и кошки"},
		{"catsandogs", "Коты и собаки"},
		{"dogs", "Собаки"},
		{"pct_test", "100% правда"},
	} {
		e.db.Exec(e.ctx, `INSERT INTO communities (slug, title, created_by) VALUES ($1, $2, $3)`, c[0], c[1], owner)
	}
	e.db.Exec(e.ctx, `INSERT INTO communities (slug, title, is_nsfw) VALUES ('cats_nsfw', 'Котики 18+', true)`)

	slugs := func(q string) string {
		t.Helper()
		items, err := e.svc.Search(e.ctx, q, 0, 20)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, c := range items {
			out = append(out, c.Slug)
		}
		return strings.Join(out, " ")
	}

	if got := slugs("CATS"); !strings.HasPrefix(got, "cats ") || strings.Contains(got, "nsfw") {
		t.Errorf("exact slug must come first, NSFW hidden: %q", got)
	}
	if got := slugs("собак"); got != "dogs catsandogs" && got != "catsandogs dogs" {
		t.Errorf("cyrillic title: %q", got)
	}
	// As wildcards "%%" would match every community; as literals, none.
	if got := slugs("%%"); got != "" {
		t.Errorf("%%%% must be literal, got %q", got)
	}
	if got := slugs("0%"); got != "pct_test" {
		t.Errorf("literal 0%% search: %q", got)
	}
	if got := slugs("к"); got != "" {
		t.Errorf("one-letter query must return nothing, got %q", got)
	}
}

func TestSubscriptions(t *testing.T) {
	e := newEnv(t)
	owner := testdb.CreateUser(t, e.db, "owner")
	reader := testdb.CreateUser(t, e.db, "reader")
	e.create(t, owner, "zeta", "Яблоки")
	e.create(t, owner, "alpha", "Арбузы")
	e.create(t, owner, "other", "Не подписан")
	e.svc.Subscribe(e.ctx, "zeta", reader)
	e.svc.Subscribe(e.ctx, "alpha", reader)

	items, err := e.svc.Subscriptions(e.ctx, reader)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || items[0].Slug != "alpha" || items[1].Slug != "zeta" || !items[0].IsSubscribed {
		t.Errorf("subscriptions = %+v", items)
	}
}
