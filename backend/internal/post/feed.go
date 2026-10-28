package post

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

type Sort string

const (
	SortHot Sort = "hot"
	SortNew Sort = "new"
)

func ParseSort(s string) (Sort, bool) {
	switch Sort(s) {
	case "", SortHot:
		return SortHot, true
	case SortNew:
		return SortNew, true
	}
	return "", false
}

// Cursor is the last post of the previous page. Rank is unused for "new",
// where ids alone are monotonic.
type Cursor struct {
	Rank float64 `json:"r,omitempty"`
	ID   int64   `json:"i"`
}

func CursorAfter(p Post) Cursor {
	return Cursor{Rank: p.HotRank, ID: p.ID}
}

type FeedQuery struct {
	Sort   Sort
	After  *Cursor // nil for the first page
	Limit  int
	Viewer int64 // fills MyVote; 0 = anonymous
}

// keyset returns the WHERE and ORDER BY fragments for the sort, with its
// cursor values appended to args. With no cursor it starts above every real
// row, so the first page runs the same query (and plan) as the rest.
func keyset(q FeedQuery, args []any) (where, order string, _ []any) {
	cur := Cursor{Rank: math.MaxFloat64, ID: math.MaxInt64}
	if q.After != nil {
		cur = *q.After
	}
	if q.Sort == SortNew {
		args = append(args, cur.ID)
		return fmt.Sprintf("p.id < $%d", len(args)), "p.id DESC", args
	}
	args = append(args, cur.Rank, cur.ID)
	return fmt.Sprintf("(p.hot_rank, p.id) < ($%d, $%d)", len(args)-1, len(args)),
		"p.hot_rank DESC, p.id DESC", args
}

func (s *Service) collect(ctx context.Context, sql string, args []any) ([]Post, error) {
	rows, err := s.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Post{}
	for rows.Next() {
		p, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// FeedAll is the front page. NSFW posts stay out of it: App Store rules
// require such content to be hidden unless the user opted in.
func (s *Service) FeedAll(ctx context.Context, q FeedQuery) ([]Post, error) {
	where, order, args := keyset(q, []any{q.Viewer})
	args = append(args, q.Limit)
	sql := fmt.Sprintf(selectPost(true), "posts") + `
		WHERE p.deleted_at IS NULL AND NOT p.is_nsfw AND ` + where + `
		ORDER BY ` + order + fmt.Sprintf(" LIMIT $%d", len(args))
	return s.collect(ctx, sql, args)
}

// FeedCommunity shows everything in the community, NSFW included: the
// viewer opened it on purpose and the app gates it.
func (s *Service) FeedCommunity(ctx context.Context, slug string, q FeedQuery) ([]Post, error) {
	var communityID int64
	err := s.db.QueryRow(ctx, `SELECT id FROM communities WHERE slug = $1`, slug).Scan(&communityID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrCommunityNotFound
	}
	if err != nil {
		return nil, err
	}

	where, order, args := keyset(q, []any{q.Viewer, communityID})
	args = append(args, q.Limit)
	sql := fmt.Sprintf(selectPost(true), "posts") + `
		WHERE p.deleted_at IS NULL AND p.community_id = $2 AND ` + where + `
		ORDER BY ` + order + fmt.Sprintf(" LIMIT $%d", len(args))
	return s.collect(ctx, sql, args)
}

// FeedSubscriptions merges the viewer's communities. For each community the
// LATERAL subquery takes only its top `limit` posts from the per-community
// index, then those few rows are merged: the cost grows with the number of
// subscriptions, not with the number of posts in them.
//
// The subscriber is the viewer: q.Viewer is ignored and userID fills $1.
func (s *Service) FeedSubscriptions(ctx context.Context, userID int64, q FeedQuery) ([]Post, error) {
	where, order, args := keyset(q, []any{userID})
	args = append(args, q.Limit)
	limit := fmt.Sprintf("$%d", len(args))
	from := `(
		SELECT lp.* FROM community_members m
		CROSS JOIN LATERAL (
			SELECT * FROM posts p
			WHERE p.community_id = m.community_id AND p.deleted_at IS NULL AND ` + where + `
			ORDER BY ` + order + `
			LIMIT ` + limit + `
		) lp
		WHERE m.user_id = $1
	)`
	sql := fmt.Sprintf(selectPost(true), from) + `
		ORDER BY ` + order + ` LIMIT ` + limit
	return s.collect(ctx, sql, args)
}

// MinSearchLen: a trigram index cannot narrow two letters down, and
// searching for them read the whole table (1.8 s on a million posts).
const MinSearchLen = 3

// Search matches titles anywhere, hottest first, in pages like a feed.
//
// Hotness, not closeness, is the order on purpose: ordering by similarity
// made Postgres find, score and sort every match (0.6-1 s for a common word
// on a million posts). Ordered by hot_rank it either walks posts_hot_idx and
// stops at the limit (common words: ~1 ms) or takes the few trigram matches
// (rare ones: ~20 ms). The match runs first, on its own, so the joins of
// selectPost run for one page only. NSFW posts and communities stay out, as
// in every discovery list.
func (s *Service) Search(ctx context.Context, query string, q FeedQuery) ([]Post, error) {
	query = strings.TrimSpace(query)
	if utf8.RuneCountInString(query) < MinSearchLen {
		return []Post{}, nil
	}
	q.Sort = SortHot
	where, order, args := keyset(q, []any{q.Viewer, "%" + likeEscaper.Replace(query) + "%"})
	args = append(args, q.Limit)
	from := `(
		SELECT p.* FROM posts p JOIN communities c ON c.id = p.community_id
		WHERE p.deleted_at IS NULL AND NOT p.is_nsfw AND NOT c.is_nsfw AND p.title ILIKE $2 AND ` + where + `
		ORDER BY ` + order + fmt.Sprintf(" LIMIT $%d", len(args)) + `
	)`
	return s.collect(ctx, fmt.Sprintf(selectPost(true), from)+` ORDER BY `+order, args)
}

var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// ByAuthor lists a user's posts, newest first, through posts_author_idx.
// NSFW posts are shown only to the author: elsewhere a profile would bypass
// the default NSFW filter.
func (s *Service) ByAuthor(ctx context.Context, authorID int64, q FeedQuery) ([]Post, error) {
	q.Sort = SortNew
	where, order, args := keyset(q, []any{q.Viewer, authorID})
	args = append(args, q.Limit)
	sql := fmt.Sprintf(selectPost(true), "posts") + `
		WHERE p.deleted_at IS NULL AND p.author_id = $2 AND (NOT p.is_nsfw OR p.author_id = $1) AND ` + where + `
		ORDER BY ` + order + fmt.Sprintf(" LIMIT $%d", len(args))
	return s.collect(ctx, sql, args)
}
