package comment

import (
	"cmp"
	"context"
	"fmt"
	"math"
	"slices"
)

type Sort string

const (
	SortBest Sort = "best"
	SortNew  Sort = "new"
)

func ParseSort(s string) (Sort, bool) {
	switch Sort(s) {
	case "", SortBest:
		return SortBest, true
	case SortNew:
		return SortNew, true
	}
	return "", false
}

// Cursor is the last sibling shown. Score is unused for "new".
type Cursor struct {
	Score int   `json:"s,omitempty"`
	ID    int64 `json:"i"`
}

func cursorAfter(c Comment) Cursor {
	return Cursor{Score: c.Score, ID: c.ID}
}

type ItemKind string

const (
	KindComment ItemKind = "comment"
	// KindMore: the parent has Count more replies; load them in place with
	// Replies(ParentID, After).
	KindMore ItemKind = "more"
	// KindContinue: the thread goes deeper than one screen can indent; the
	// app opens Replies(ParentID) as a new screen.
	KindContinue ItemKind = "continue"
)

// Item is one row of the thread exactly as the app draws it: comments in
// display order (depth-first) with stubs where replies were cut. The client
// needs no tree logic, only indentation by Depth.
type Item struct {
	Kind    ItemKind
	Comment *Comment // KindComment only

	// Stubs only.
	ParentID int64
	Depth    int
	Count    int
	After    *Cursor // KindMore: continue after the replies already shown
}

type Page struct {
	Items []Item
	Next  *Cursor // more items at the page's own level
}

type Query struct {
	Sort   Sort
	After  *Cursor
	Limit  int
	Viewer int64
}

const (
	// Levels per response: the page's comments and 5 levels of replies.
	// Deeper on a phone the text column gets too narrow; "continue" opens
	// the rest as a new screen.
	levels = 6
	// Replies shown per comment before a "more" stub, like Reddit's app.
	repliesPerNode = 8
	// Hard cap on a response: a viral thread must not produce a 2 MB page.
	maxTreeRows = 400
)

// Thread loads a page of a post's top-level comments with their replies.
func (s *Service) Thread(ctx context.Context, postID int64, q Query) (Page, error) {
	var exists bool
	if err := s.db.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM posts WHERE id = $1 AND deleted_at IS NULL)`, postID).Scan(&exists); err != nil {
		return Page{}, err
	}
	if !exists {
		return Page{}, ErrPostNotFound
	}
	return s.load(ctx, "c.post_id = $2 AND c.parent_id IS NULL", postID, q)
}

// Replies loads a page of a comment's direct replies with their replies.
func (s *Service) Replies(ctx context.Context, parentID int64, q Query) (Page, error) {
	var exists bool
	if err := s.db.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM comments WHERE id = $1)`, parentID).Scan(&exists); err != nil {
		return Page{}, err
	}
	if !exists {
		return Page{}, ErrNotFound
	}
	return s.load(ctx, "c.parent_id = $2", parentID, q)
}

// orderBy is the sibling order. "Best" breaks score ties by age, so the
// earlier of two equal comments stays on top.
func orderBy(sort Sort, alias string) string {
	if sort == SortNew {
		return alias + ".id DESC"
	}
	return alias + ".score DESC, " + alias + ".id"
}

// keyset appends the cursor to args and returns the matching condition.
func keyset(q Query, args []any) (string, []any) {
	if q.Sort == SortNew {
		id := int64(math.MaxInt64)
		if q.After != nil {
			id = q.After.ID
		}
		args = append(args, id)
		return fmt.Sprintf("c.id < $%d", len(args)), args
	}
	cur := Cursor{Score: math.MaxInt32}
	if q.After != nil {
		cur = *q.After
	}
	args = append(args, cur.Score, cur.ID)
	s, i := len(args)-1, len(args)
	// Mixed directions (score DESC, id ASC) rule out a row comparison.
	return fmt.Sprintf("(c.score < $%d OR (c.score = $%d AND c.id > $%d))", s, s, i), args
}

const rawCols = `c.id, c.post_id, c.parent_id, c.depth, c.body, c.deleted_at,
	c.score, c.reply_count, c.created_at, c.edited_at, c.author_id`

func (s *Service) load(ctx context.Context, filter string, filterArg int64, q Query) (Page, error) {
	cond, args := keyset(q, []any{q.Viewer, filterArg})
	args = append(args, q.Limit)
	pageSQL := project(`(
		SELECT `+rawCols+` FROM comments c
		WHERE `+filter+` AND `+cond+`
		ORDER BY `+orderBy(q.Sort, "c")+fmt.Sprintf(" LIMIT $%d", len(args))+`
	)`) + ` ORDER BY ` + orderBy(q.Sort, "t")
	page, err := s.collect(ctx, pageSQL, args...)
	if err != nil || len(page) == 0 {
		return Page{Items: []Item{}}, err
	}

	ids := make([]int64, len(page))
	for i, c := range page {
		ids[i] = c.ID
	}
	tree, err := s.collect(ctx, treeSQL(q.Sort), q.Viewer, ids, levels-1, repliesPerNode, maxTreeRows)
	if err != nil {
		return Page{}, err
	}

	out := Page{Items: flatten(page, tree, q.Sort)}
	if len(page) == q.Limit {
		next := cursorAfter(page[len(page)-1])
		out.Next = &next
	}
	return out, nil
}

// treeSQL walks down from the page's comments level by level, taking each
// parent's top repliesPerNode replies ($4) from the per-parent index, for at
// most $3 levels. Postgres evaluates a recursive CTE only as far as the
// outer LIMIT ($5) reads, and level by level, so the cap cuts the deepest
// replies first and a parent's replies are always a prefix of its sorted list.
func treeSQL(sort Sort) string {
	order := orderBy(sort, "c")
	return `
	WITH RECURSIVE tree AS (
		SELECT x.*, 1 AS lvl FROM unnest($2::bigint[]) AS p(id)
		CROSS JOIN LATERAL (
			SELECT ` + rawCols + ` FROM comments c WHERE c.parent_id = p.id ORDER BY ` + order + ` LIMIT $4
		) x
		UNION ALL
		SELECT x.*, tr.lvl + 1 FROM tree tr
		CROSS JOIN LATERAL (
			SELECT ` + rawCols + ` FROM comments c WHERE c.parent_id = tr.id ORDER BY ` + order + ` LIMIT $4
		) x
		WHERE tr.lvl < $3
	)` + project("(SELECT * FROM tree LIMIT $5)")
}

func (s *Service) collect(ctx context.Context, sql string, args ...any) ([]Comment, error) {
	rows, err := s.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Comment
	for rows.Next() {
		c, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// flatten lays the tree out depth-first. A comment whose loaded replies fall
// short of its reply_count gets a stub: "more" with a cursor after the last
// shown reply, or "continue" at the last level.
func flatten(page, tree []Comment, sort Sort) []Item {
	children := map[int64][]Comment{}
	for _, c := range tree {
		children[*c.ParentID] = append(children[*c.ParentID], c)
	}
	for _, kids := range children {
		slices.SortFunc(kids, func(a, b Comment) int {
			if sort == SortNew {
				return cmp.Compare(b.ID, a.ID)
			}
			return cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(a.ID, b.ID))
		})
	}

	items := make([]Item, 0, len(page)+len(tree))
	var walk func(c Comment, level int)
	walk = func(c Comment, level int) {
		items = append(items, Item{Kind: KindComment, Comment: &c})
		kids := children[c.ID]
		for _, k := range kids {
			walk(k, level+1)
		}
		missing := c.ReplyCount - len(kids)
		if missing <= 0 {
			return
		}
		stub := Item{Kind: KindMore, ParentID: c.ID, Depth: c.Depth + 1, Count: missing}
		if level == levels-1 {
			stub.Kind = KindContinue
		} else if len(kids) > 0 {
			after := cursorAfter(kids[len(kids)-1])
			stub.After = &after
		}
		items = append(items, stub)
	}
	for _, c := range page {
		walk(c, 0)
	}
	return items
}
