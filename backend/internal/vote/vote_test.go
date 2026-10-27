package vote

import (
	"context"
	"errors"
	"fmt"
	"math"
	"math/rand/v2"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/ranking"
	"vetka/internal/testdb"
)

type allowAll struct{}

func (allowAll) Allow(context.Context, string, int, time.Duration) (bool, error) { return true, nil }

type denyAll struct{}

func (denyAll) Allow(context.Context, string, int, time.Duration) (bool, error) { return false, nil }

type env struct {
	svc *Service
	db  *pgxpool.Pool
	ctx context.Context
}

func newEnv(t *testing.T) env {
	t.Helper()
	db := testdb.New(t)
	return env{svc: NewService(db, allowAll{}), db: db, ctx: context.Background()}
}

func (e env) post(t *testing.T, authorID int64) int64 {
	t.Helper()
	var communityID, id int64
	if err := e.db.QueryRow(e.ctx,
		`INSERT INTO communities (slug, title) VALUES ($1, 'x') RETURNING id`,
		fmt.Sprintf("c%d", rand.IntN(1e9))).Scan(&communityID); err != nil {
		t.Fatal(err)
	}
	if err := e.db.QueryRow(e.ctx,
		`INSERT INTO posts (community_id, author_id, title, created_at) VALUES ($1, $2, 'x', now() - interval '1 hour') RETURNING id`,
		communityID, authorID).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func (e env) flush(t *testing.T) {
	t.Helper()
	for {
		n, err := Flush(e.ctx, e.db, 1000)
		if err != nil {
			t.Fatal(err)
		}
		if n < 1000 {
			return
		}
	}
}

type counters struct{ up, down int }

func (e env) counters(t *testing.T, postID int64) counters {
	t.Helper()
	var c counters
	if err := e.db.QueryRow(e.ctx, `SELECT upvotes, downvotes FROM posts WHERE id = $1`, postID).Scan(&c.up, &c.down); err != nil {
		t.Fatal(err)
	}
	return c
}

func (e env) karma(t *testing.T, userID int64) int {
	t.Helper()
	var k int
	if err := e.db.QueryRow(e.ctx, `SELECT post_karma FROM users WHERE id = $1`, userID).Scan(&k); err != nil {
		t.Fatal(err)
	}
	return k
}

func TestDelta(t *testing.T) {
	tests := []struct{ from, to, up, down int }{
		{0, 1, 1, 0}, {0, -1, 0, 1}, {1, 0, -1, 0}, {-1, 0, 0, -1},
		{1, -1, -1, 1}, {-1, 1, 1, -1}, {1, 1, 0, 0}, {0, 0, 0, 0},
	}
	for _, tt := range tests {
		if up, down := delta(tt.from, tt.to); up != tt.up || down != tt.down {
			t.Errorf("delta(%d→%d) = %d,%d; want %d,%d", tt.from, tt.to, up, down, tt.up, tt.down)
		}
	}
}

func TestVoteTransitions(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	voter := testdb.CreateUser(t, e.db, "voter")
	postID := e.post(t, author)

	steps := []struct {
		value     int
		want      counters
		wantKarma int
	}{
		{1, counters{1, 0}, 1},
		{1, counters{1, 0}, 1}, // repeat: no change
		{-1, counters{0, 1}, -1},
		{0, counters{0, 0}, 0},
		{0, counters{0, 0}, 0}, // clearing twice is fine
		{-1, counters{0, 1}, -1},
	}
	for i, s := range steps {
		res, err := e.svc.VotePost(e.ctx, voter, postID, s.value)
		if err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
		// The response already counts the delta the worker has not applied.
		if res.MyVote != s.value || res.Score != s.want.up-s.want.down {
			t.Errorf("step %d: response %+v, want vote %d score %d", i, res, s.value, s.want.up-s.want.down)
		}
		e.flush(t)
		if got := e.counters(t, postID); got != s.want {
			t.Errorf("step %d (vote %d): counters %+v, want %+v", i, s.value, got, s.want)
		}
		if got := e.karma(t, author); got != s.wantKarma {
			t.Errorf("step %d: karma %d, want %d", i, got, s.wantKarma)
		}
	}
}

func TestSelfVoteMovesScoreNotKarma(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	postID := e.post(t, author)

	if _, err := e.svc.VotePost(e.ctx, author, postID, 1); err != nil {
		t.Fatal(err)
	}
	e.flush(t)
	if c := e.counters(t, postID); c.up != 1 {
		t.Errorf("self-vote must count in score: %+v", c)
	}
	if k := e.karma(t, author); k != 0 {
		t.Errorf("self-vote must not give karma: %d", k)
	}
}

func TestHotRankFollowsVotes(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	postID := e.post(t, author)
	for i := range 9 {
		e.svc.VotePost(e.ctx, testdb.CreateUser(t, e.db, fmt.Sprintf("voter%d", i)), postID, 1)
	}
	e.flush(t)

	var rank float64
	var created time.Time
	e.db.QueryRow(e.ctx, `SELECT hot_rank, created_at FROM posts WHERE id = $1`, postID).Scan(&rank, &created)
	if want := ranking.Hot(9, 0, created); math.Abs(rank-want) > 1e-9 {
		t.Errorf("hot_rank = %v, want ranking.Hot(9, 0) = %v", rank, want)
	}
}

func TestVoteErrors(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	postID := e.post(t, author)

	if _, err := e.svc.VotePost(e.ctx, author, postID, 2); !errors.Is(err, ErrInvalidValue) {
		t.Errorf("value 2: %v", err)
	}
	if _, err := e.svc.VotePost(e.ctx, author, 999999, 1); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown post: %v", err)
	}
	e.db.Exec(e.ctx, `UPDATE posts SET deleted_at = now() WHERE id = $1`, postID)
	if _, err := e.svc.VotePost(e.ctx, author, postID, 1); !errors.Is(err, ErrNotFound) {
		t.Errorf("deleted post: %v", err)
	}
	limited := NewService(e.db, denyAll{})
	if _, err := limited.VotePost(e.ctx, author, e.post(t, author), 1); !errors.Is(err, ErrRateLimited) {
		t.Errorf("rate limit: %v", err)
	}
}

// TestConcurrentVotesKeepCountersExact is the invariant that matters: however
// votes interleave (double taps, flips, concurrent flushes), the counters end
// up equal to a recount of the votes themselves.
func TestConcurrentVotesKeepCountersExact(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	posts := []int64{e.post(t, author), e.post(t, author)}
	var voters []int64
	for i := range 20 {
		voters = append(voters, testdb.CreateUser(t, e.db, fmt.Sprintf("voter%02d", i)))
	}

	var wg sync.WaitGroup
	for _, v := range voters {
		for range 3 { // three concurrent "taps" per voter
			wg.Go(func() {
				for range 15 {
					p := posts[rand.IntN(len(posts))]
					if _, err := e.svc.VotePost(e.ctx, v, p, rand.IntN(3)-1); err != nil {
						t.Error(err)
						return
					}
				}
			})
		}
	}
	// A flusher racing with the voters.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range 30 {
			if _, err := Flush(e.ctx, e.db, 50); err != nil {
				t.Error(err)
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()
	wg.Wait()
	<-done
	e.flush(t)

	for _, p := range posts {
		var want counters
		e.db.QueryRow(e.ctx, `
			SELECT count(*) FILTER (WHERE value = 1), count(*) FILTER (WHERE value = -1)
			FROM post_votes WHERE post_id = $1`, p).Scan(&want.up, &want.down)
		if got := e.counters(t, p); got != want {
			t.Errorf("post %d: counters %+v, recount %+v", p, got, want)
		}
	}
	var wantKarma int
	e.db.QueryRow(e.ctx, `SELECT COALESCE(sum(value), 0) FROM post_votes`).Scan(&wantKarma)
	if got := e.karma(t, author); got != wantKarma {
		t.Errorf("karma %d, recount %d", got, wantKarma)
	}
	var pending int
	e.db.QueryRow(e.ctx, `SELECT count(*) FROM vote_deltas`).Scan(&pending)
	if pending != 0 {
		t.Errorf("%d deltas left after the final flush", pending)
	}
}

func TestFlushTakesBatches(t *testing.T) {
	e := newEnv(t)
	author := testdb.CreateUser(t, e.db, "author")
	postID := e.post(t, author)
	for i := range 5 {
		e.svc.VotePost(e.ctx, testdb.CreateUser(t, e.db, fmt.Sprintf("voter%d", i)), postID, 1)
	}

	for _, want := range []int{2, 2, 1, 0} {
		if n, err := Flush(e.ctx, e.db, 2); err != nil || n != want {
			t.Fatalf("Flush = %d, %v; want %d", n, err, want)
		}
	}
	if c := e.counters(t, postID); c.up != 5 {
		t.Errorf("counters %+v, want 5 up", c)
	}
}
