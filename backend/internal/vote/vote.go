// Package vote records votes and keeps counters, hot rank and karma in sync.
//
// The write path stores the vote and a counter delta in one transaction
// (vote_deltas is an outbox). Flush, run by the worker, folds pending deltas
// into posts, comments and users in batches.
package vote

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrNotFound     = errors.New("vote: target not found")
	ErrInvalidValue = errors.New("vote: value must be -1, 0 or 1")
	ErrRateLimited  = errors.New("vote: too many votes")
)

type Limiter interface {
	Allow(ctx context.Context, key string, limit int, window time.Duration) (bool, error)
}

// Bots vote fast; people do not sustain more than a couple of votes a second.
const votesPerMinute = 120

type Service struct {
	db      *pgxpool.Pool
	limiter Limiter
}

func NewService(db *pgxpool.Pool, limiter Limiter) *Service {
	return &Service{db: db, limiter: limiter}
}

// Result is what the client reconciles its optimistic state with.
type Result struct {
	MyVote int
	Score  int // includes deltas the worker has not applied yet
}

// target describes a votable table. Names are constants, never user input.
type target struct {
	kind  string // vote_deltas.target
	table string // posts, comments
	votes string // post_votes, comment_votes
	idCol string // the votes table's reference column
}

var (
	postTarget    = target{kind: "post", table: "posts", votes: "post_votes", idCol: "post_id"}
	commentTarget = target{kind: "comment", table: "comments", votes: "comment_votes", idCol: "comment_id"}
)

// VotePost sets the user's vote on a post to value: 1, -1, or 0 to clear it.
// It sets a state rather than toggling, so retries and double taps are safe.
func (s *Service) VotePost(ctx context.Context, userID, postID int64, value int) (Result, error) {
	return s.vote(ctx, postTarget, userID, postID, value)
}

// VoteComment is VotePost for comments; the karma goes to comment_karma.
func (s *Service) VoteComment(ctx context.Context, userID, commentID int64, value int) (Result, error) {
	return s.vote(ctx, commentTarget, userID, commentID, value)
}

func (s *Service) vote(ctx context.Context, t target, userID, id int64, value int) (Result, error) {
	if value < -1 || value > 1 {
		return Result{}, ErrInvalidValue
	}
	ok, err := s.limiter.Allow(ctx, "vote:"+strconv.FormatInt(userID, 10), votesPerMinute, time.Minute)
	if err != nil {
		return Result{}, err
	}
	if !ok {
		return Result{}, ErrRateLimited
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Result{}, err
	}
	defer tx.Rollback(ctx)

	var authorID *int64
	err = tx.QueryRow(ctx, `SELECT author_id FROM `+t.table+` WHERE id = $1 AND deleted_at IS NULL`, id).Scan(&authorID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Result{}, ErrNotFound
	}
	if err != nil {
		return Result{}, err
	}

	old, err := setVote(ctx, tx, t, userID, id, value)
	if err != nil {
		return Result{}, err
	}
	if old != value {
		// Self-votes move the score but not karma: no farming your own content.
		karmaTo := authorID
		if authorID != nil && *authorID == userID {
			karmaTo = nil
		}
		up, down := delta(old, value)
		if _, err := tx.Exec(ctx, `
			INSERT INTO vote_deltas (target, target_id, author_id, up, down)
			VALUES ($1, $2, $3, $4, $5)`, t.kind, id, karmaTo, up, down); err != nil {
			return Result{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Result{}, err
	}

	var score int
	if err := s.db.QueryRow(ctx, `
		SELECT x.score + COALESCE((
			SELECT sum(d.up - d.down) FROM vote_deltas d WHERE d.target = $2 AND d.target_id = x.id
		), 0)::int
		FROM `+t.table+` x WHERE x.id = $1`, id, t.kind).Scan(&score); err != nil {
		return Result{}, err
	}
	return Result{MyVote: value, Score: score}, nil
}

// setVote stores the vote and returns the previous value, atomically even
// when the same user votes twice concurrently.
//
// Values are only ±1, so the previous one follows from what the upsert did:
// inserted → 0, updated (only when the value differs) → the opposite,
// untouched → the same. `xmax = 0` is true for a freshly inserted row.
func setVote(ctx context.Context, tx pgx.Tx, t target, userID, id int64, value int) (old int, err error) {
	if value == 0 {
		err := tx.QueryRow(ctx,
			`DELETE FROM `+t.votes+` WHERE user_id = $1 AND `+t.idCol+` = $2 RETURNING value`,
			userID, id).Scan(&old)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, nil
		}
		return old, err
	}

	var inserted bool
	err = tx.QueryRow(ctx, `
		INSERT INTO `+t.votes+` AS v (user_id, `+t.idCol+`, value) VALUES ($1, $2, $3)
		ON CONFLICT (user_id, `+t.idCol+`) DO UPDATE SET value = EXCLUDED.value, created_at = now()
		WHERE v.value <> EXCLUDED.value
		RETURNING xmax = 0`, userID, id, value).Scan(&inserted)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return value, nil // already this value
	case err != nil:
		return 0, err
	case inserted:
		return 0, nil
	default:
		return -value, nil
	}
}

// delta converts a vote change into counter increments.
func delta(from, to int) (up, down int) {
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	return b(to == 1) - b(from == 1), b(to == -1) - b(from == -1)
}
