package user

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"vetka/internal/testdb"
)

func TestUpdateProfileFields(t *testing.T) {
	db := testdb.New(t)
	s, ctx := NewStore(db), context.Background()
	id := testdb.CreateUser(t, db, "ivan")

	u, err := s.Update(ctx, id, UpdateInput{DisplayName: new("  Иван  "), Bio: new("Люблю котиков")})
	if err != nil || *u.DisplayName != "Иван" || *u.Bio != "Люблю котиков" {
		t.Fatalf("update: %+v, %v", u, err)
	}
	// Omitted fields stay, an empty one clears.
	u, err = s.Update(ctx, id, UpdateInput{Bio: new("")})
	if err != nil || u.Bio != nil || u.DisplayName == nil {
		t.Errorf("clear bio: %+v, %v", u, err)
	}
	var verr *ValidationError
	if _, err := s.Update(ctx, id, UpdateInput{Bio: new(strings.Repeat("я", maxBio+1))}); !errors.As(err, &verr) || verr.Field != "bio" {
		t.Errorf("long bio: %v", err)
	}
}

func TestUsernameChangePolicy(t *testing.T) {
	db := testdb.New(t)
	s, ctx := NewStore(db), context.Background()
	now := time.Now()
	s.now = func() time.Time { return now }
	id := testdb.CreateUser(t, db, "user_abc12345")
	testdb.CreateUser(t, db, "Taken")

	u, err := s.Get(ctx, id)
	if err != nil || u.UsernameChangeableAt != nil {
		t.Fatalf("new account must be able to pick a name now: %+v, %v", u, err)
	}

	// First change is free (onboarding).
	u, err = s.Update(ctx, id, UpdateInput{Username: new("ivan")})
	if err != nil || u.Username != "ivan" || u.UsernameChangeableAt == nil {
		t.Fatalf("first change: %+v, %v", u, err)
	}
	if _, err := s.Update(ctx, id, UpdateInput{Username: new("ivan2")}); !errors.Is(err, ErrUsernameChangeTooSoon) {
		t.Errorf("second change within 30 days: %v", err)
	}
	// Fixing letter case is not a new name.
	if u, err := s.Update(ctx, id, UpdateInput{Username: new("Ivan")}); err != nil || u.Username != "Ivan" {
		t.Errorf("case-only change: %+v, %v", u, err)
	}

	now = now.Add(31 * 24 * time.Hour)
	if _, err := s.Update(ctx, id, UpdateInput{Username: new("TAKEN")}); !errors.Is(err, ErrUsernameTaken) {
		t.Errorf("taken (case-insensitive): %v", err)
	}
	var verr *ValidationError
	for _, bad := range []string{"ab", "иван", "Admin", "deleted_42"} {
		if _, err := s.Update(ctx, id, UpdateInput{Username: new(bad)}); !errors.As(err, &verr) {
			t.Errorf("%q: %v, want a validation error", bad, err)
		}
	}
	if u, err := s.Update(ctx, id, UpdateInput{Username: new("ivan_new")}); err != nil || u.Username != "ivan_new" {
		t.Errorf("change after cooldown: %+v, %v", u, err)
	}
}

func TestUsernameAvailable(t *testing.T) {
	db := testdb.New(t)
	s, ctx := NewStore(db), context.Background()
	testdb.CreateUser(t, db, "ivan")

	if err := s.UsernameAvailable(ctx, "petr"); err != nil {
		t.Errorf("free: %v", err)
	}
	if err := s.UsernameAvailable(ctx, "IVAN"); !errors.Is(err, ErrUsernameTaken) {
		t.Errorf("taken: %v", err)
	}
	var verr *ValidationError
	if err := s.UsernameAvailable(ctx, "support"); !errors.As(err, &verr) {
		t.Errorf("reserved: %v", err)
	}
}

func TestDeleteAccount(t *testing.T) {
	db := testdb.New(t)
	s, ctx := NewStore(db), context.Background()
	id := testdb.CreateUser(t, db, "ivan")
	var communityID int64
	db.QueryRow(ctx, `INSERT INTO communities (slug, title, created_by) VALUES ('news', 'x', $1) RETURNING id`, id).Scan(&communityID)
	db.Exec(ctx, `INSERT INTO community_members (user_id, community_id) VALUES ($1, $2)`, id, communityID)
	db.Exec(ctx, `INSERT INTO community_moderators (community_id, user_id, role) VALUES ($1, $2, 'owner')`, communityID, id)
	db.Exec(ctx, `INSERT INTO auth_identities (provider, subject, user_id) VALUES ('telegram', '42', $1)`, id)
	db.Exec(ctx, `INSERT INTO refresh_tokens (user_id, token_hash, family_id, expires_at)
		VALUES ($1, 'h', gen_random_uuid(), now() + interval '1 day')`, id)
	db.Exec(ctx, `INSERT INTO posts (community_id, author_id, title) VALUES ($1, $2, 'останется')`, communityID, id)

	if err := s.Delete(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, id); !errors.Is(err, ErrNotFound) {
		t.Errorf("deleted user still readable: %v", err)
	}
	if err := s.UsernameAvailable(ctx, "ivan"); err != nil {
		t.Errorf("username must be freed: %v", err)
	}

	var identities, liveTokens, members, mods, subscribers, posts int
	db.QueryRow(ctx, `SELECT count(*) FROM auth_identities WHERE user_id = $1`, id).Scan(&identities)
	db.QueryRow(ctx, `SELECT count(*) FROM refresh_tokens WHERE user_id = $1 AND revoked_at IS NULL`, id).Scan(&liveTokens)
	db.QueryRow(ctx, `SELECT count(*) FROM community_members WHERE user_id = $1`, id).Scan(&members)
	db.QueryRow(ctx, `SELECT count(*) FROM community_moderators WHERE user_id = $1`, id).Scan(&mods)
	db.QueryRow(ctx, `SELECT subscribers_count FROM communities WHERE id = $1`, communityID).Scan(&subscribers)
	db.QueryRow(ctx, `SELECT count(*) FROM posts WHERE author_id = $1 AND deleted_at IS NULL`, id).Scan(&posts)
	if identities != 0 || liveTokens != 0 || members != 0 || mods != 0 || subscribers != 0 {
		t.Errorf("left behind: identities=%d tokens=%d members=%d mods=%d subscribers=%d",
			identities, liveTokens, members, mods, subscribers)
	}
	if posts != 1 {
		t.Errorf("posts must stay (authorless): %d", posts)
	}
	if err := s.Delete(ctx, id); !errors.Is(err, ErrNotFound) {
		t.Errorf("second delete: %v", err)
	}
}

func TestSearch(t *testing.T) {
	db := testdb.New(t)
	s := NewStore(db)
	ctx := context.Background()
	ivan := testdb.CreateUser(t, db, "ivan")
	testdb.CreateUser(t, db, "ivanov_petr")
	maria := testdb.CreateUser(t, db, "masha")
	if _, err := s.Update(ctx, maria, UpdateInput{DisplayName: new("Мария Иванова")}); err != nil {
		t.Fatal(err)
	}
	gone := testdb.CreateUser(t, db, "ivan_gone")
	if err := s.Delete(ctx, gone); err != nil {
		t.Fatal(err)
	}

	got, err := s.Search(ctx, "Ivan", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != ivan {
		t.Errorf("search ivan = %+v, want ivan first and no deleted account", got)
	}
	if got, _ := s.Search(ctx, "иванова", 10); len(got) != 1 || got[0].ID != maria {
		t.Errorf("display name search = %+v", got)
	}
	// Usernames match from the start only; display names anywhere.
	if got, _ := s.Search(ctx, "petr", 10); len(got) != 0 {
		t.Errorf("middle of a username matched: %+v", got)
	}
	if got, _ := s.Search(ctx, "iv", 10); len(got) != 0 {
		t.Errorf("two letters matched: %+v", got)
	}
}

// The follow counters change once per statement: many rows at once must
// count per person, both ways, and an account with a crowd of followers
// must delete in one quick statement.
func TestFollowCountersInBulk(t *testing.T) {
	db := testdb.New(t)
	s, ctx := NewStore(db), context.Background()
	star := testdb.CreateUser(t, db, "star")
	fan := testdb.CreateUser(t, db, "fan")
	const crowd = 2000
	if _, err := db.Exec(ctx, `INSERT INTO users (username) SELECT 'user_' || g FROM generate_series(1, $1) g`, crowd); err != nil {
		t.Fatal(err)
	}
	// One statement: the crowd follows star and fan follows the crowd.
	if _, err := db.Exec(ctx, `
		INSERT INTO user_follows (follower_id, followee_id)
		SELECT id, $1 FROM users WHERE username LIKE 'user\_%'
		UNION ALL
		SELECT $2, id FROM users WHERE username LIKE 'user\_%'`, star, fan); err != nil {
		t.Fatal(err)
	}
	counts := func(id int64) (followers, following int) {
		u, err := s.Get(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		return u.FollowersCount, u.FollowingCount
	}
	if f, _ := counts(star); f != crowd {
		t.Errorf("star followers = %d, want %d", f, crowd)
	}
	if _, g := counts(fan); g != crowd {
		t.Errorf("fan following = %d, want %d", g, crowd)
	}
	var someone int64
	if err := db.QueryRow(ctx, `SELECT id FROM users WHERE username = 'user_7'`).Scan(&someone); err != nil {
		t.Fatal(err)
	}
	if f, g := counts(someone); f != 1 || g != 1 {
		t.Errorf("one of the crowd: followers %d, following %d, want 1 and 1", f, g)
	}
	if _, err := s.Follow(ctx, someone, "fan"); err != nil {
		t.Fatal(err)
	}
	if f, _ := counts(fan); f != 1 {
		t.Errorf("single follow after the bulk: fan followers = %d", f)
	}

	start := time.Now()
	if err := s.Delete(ctx, star); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took > 5*time.Second {
		t.Errorf("deleting an account with %d followers took %v", crowd, took)
	}
	if f, g := counts(someone); f != 1 || g != 1 { // lost star, kept fan
		t.Errorf("after star left: followers %d, following %d, want 1 and 1", f, g)
	}
	if err := s.Delete(ctx, fan); err != nil {
		t.Fatal(err)
	}
	if f, g := counts(someone); f != 0 || g != 0 {
		t.Errorf("after fan left: followers %d, following %d, want 0 and 0", f, g)
	}
}
