package search

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"vetka/internal/testdb"
)

func TestNormalize(t *testing.T) {
	for in, want := range map[string]string{"  Юмор  И   мемы ": "юмор и мемы", "ИГРЫ": "игры"} {
		if got, ok := Normalize(in); !ok || got != want {
			t.Errorf("Normalize(%q) = %q, %v", in, got, ok)
		}
	}
	if _, ok := Normalize(" я "); ok {
		t.Error("one letter is kept")
	}
}

func TestPopularNeedsSeveralPeopleAndFallsBackToCommunities(t *testing.T) {
	db := testdb.New(t)
	ctx := context.Background()
	s := NewService(db)
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }

	if _, err := db.Exec(ctx, `INSERT INTO communities (slug, title, subscribers_count) VALUES
		('kino', 'Кино', 50), ('igry', 'Игры', 40), ('nsfw', 'Взрослое', 99)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `UPDATE communities SET is_nsfw = true WHERE slug = 'nsfw'`); err != nil {
		t.Fatal(err)
	}
	var people []int64
	for i := range 3 {
		people = append(people, testdb.CreateUser(t, db, fmt.Sprintf("user%d", i)))
	}
	for _, id := range people {
		if err := s.Record(ctx, id, "Котики"); err != nil {
			t.Fatal(err)
		}
	}
	// One person, however often, does not trend.
	for range 5 {
		if err := s.Record(ctx, people[0], "мой ник"); err != nil {
			t.Fatal(err)
		}
	}

	// Before the worker counts, the communities fill in.
	if got, _ := s.Popular(ctx, 3); !slices.Equal(got, []string{"кино", "игры"}) {
		t.Errorf("uncounted popular = %v", got)
	}
	if err := RefreshPopular(ctx, db, now); err != nil {
		t.Fatal(err)
	}
	got, err := s.Popular(ctx, 3)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"котики", "кино", "игры"}; !slices.Equal(got, want) {
		t.Errorf("popular = %v, want %v", got, want)
	}

	// A week later the searches are gone, the communities stay.
	now = now.Add(8 * 24 * time.Hour)
	if n, err := Prune(ctx, db, now); err != nil || n != 4 {
		t.Errorf("prune = %d, %v; want 4 rows", n, err)
	}
	if err := RefreshPopular(ctx, db, now); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Popular(ctx, 3); !slices.Equal(got, []string{"кино", "игры"}) {
		t.Errorf("after prune = %v", got)
	}
}
