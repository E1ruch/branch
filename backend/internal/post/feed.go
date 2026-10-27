package post

import (
	"context"
	"errors"
	"fmt"
	"math"

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
