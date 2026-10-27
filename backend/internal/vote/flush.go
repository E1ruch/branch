package vote

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// flushSQL consumes up to $1 pending deltas and applies them in one
// statement, so counters, hot rank and karma move together or not at all.
//
// SKIP LOCKED lets a second worker take a different batch instead of waiting.
// Deltas are summed per target first, so a post that got 300 votes since the
// last flush is updated once, not 300 times.
const flushSQL = `
WITH batch AS (
	DELETE FROM vote_deltas
	WHERE id IN (SELECT id FROM vote_deltas ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED)
	RETURNING target, target_id, author_id, up, down
),
post_sums AS (
	SELECT target_id AS id, sum(up)::int AS up, sum(down)::int AS down
	FROM batch WHERE target = 'post' GROUP BY target_id
),
posts_updated AS (
	UPDATE posts p SET
		upvotes   = p.upvotes + s.up,
		downvotes = p.downvotes + s.down,
		hot_rank  = hot_rank(p.upvotes + s.up, p.downvotes + s.down, p.created_at)
	FROM post_sums s WHERE p.id = s.id
),
comment_sums AS (
	SELECT target_id AS id, sum(up)::int AS up, sum(down)::int AS down
	FROM batch WHERE target = 'comment' GROUP BY target_id
),
comments_updated AS (
	UPDATE comments c SET
		upvotes   = c.upvotes + s.up,
		downvotes = c.downvotes + s.down
	FROM comment_sums s WHERE c.id = s.id
),
karma AS (
	SELECT author_id AS id,
	       COALESCE(sum(up - down) FILTER (WHERE target = 'post'), 0)::int    AS post,
	       COALESCE(sum(up - down) FILTER (WHERE target = 'comment'), 0)::int AS comment
	FROM batch WHERE author_id IS NOT NULL GROUP BY author_id
),
users_updated AS (
	UPDATE users u SET
		post_karma    = u.post_karma + k.post,
		comment_karma = u.comment_karma + k.comment
	FROM karma k WHERE u.id = k.id
)
SELECT count(*) FROM batch`

// Flush applies up to batchSize pending deltas and returns how many it took.
// A full batch means more may be waiting.
func Flush(ctx context.Context, db *pgxpool.Pool, batchSize int) (int, error) {
	var n int
	err := db.QueryRow(ctx, flushSQL, batchSize).Scan(&n)
	return n, err
}
