package comment

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/testdb"
	"vetka/internal/vote"
)

type allowAll struct{}

func (allowAll) Allow(context.Context, string, int, time.Duration) (bool, error) { return true, nil }

type denyAll struct{}

func (denyAll) Allow(context.Context, string, int, time.Duration) (bool, error) { return false, nil }

type env struct {
	svc    *Service
	db     *pgxpool.Pool
	ctx    context.Context
	author int64
	postID int64
}

func newEnv(t *testing.T) env {
	t.Helper()
	db := testdb.New(t)
	e := env{svc: NewService(db, allowAll{}), db: db, ctx: context.Background()}
	e.author = testdb.CreateUser(t, db, "author")
	e.postID = e.newPost(t)
	return e
}

func (e env) newPost(t *testing.T) int64 {
	t.Helper()
	var communityID, id int64
	e.db.QueryRow(e.ctx, `INSERT INTO communities (slug, title) VALUES ($1, 'x') RETURNING id`,
		fmt.Sprintf("c%d", time.Now().UnixNano())).Scan(&communityID)
	if err := e.db.QueryRow(e.ctx, `INSERT INTO posts (community_id, author_id, title) VALUES ($1, $2, 'x') RETURNING id`,
		communityID, e.author).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

// add creates a comment by body and sets its score directly, as votes would.
func (e env) add(t *testing.T, parent *Comment, body string, score int) Comment {
	t.Helper()
	var parentID *int64
	if parent != nil {
		parentID = &parent.ID
	}
	c, err := e.svc.Create(e.ctx, e.author, e.postID, parentID, body)
	if err != nil {
		t.Fatalf("add %s: %v", body, err)
	}
	if score != 0 {
		e.db.Exec(e.ctx, `UPDATE comments SET upvotes = $2 WHERE id = $1`, c.ID, score)
		c.Score = score
	}
	return c
}

// layout renders items as "body@depth" and stubs as "+kind(count)@depth".
func layout(items []Item) string {
	var parts []string
	for _, it := range items {
		if it.Kind == KindComment {
			parts = append(parts, fmt.Sprintf("%s@%d", it.Comment.Body, it.Comment.Depth))
		} else {
			parts = append(parts, fmt.Sprintf("+%s(%d)@%d", it.Kind, it.Count, it.Depth))
		}
	}
	return strings.Join(parts, " ")
}

// checkCounts asserts the core invariant: under every comment, the replies
// shown plus the replies promised by its stub add up to reply_count.
func checkCounts(t *testing.T, items []Item) {
	t.Helper()
	for i, it := range items {
		if it.Kind != KindComment {
			continue
		}
		c := it.Comment
		got := 0
		for _, next := range items[i+1:] {
			if next.Kind == KindComment && next.Comment.Depth <= c.Depth {
				break
			}
			switch {
			case next.Kind == KindComment && next.Comment.Depth == c.Depth+1:
				got++
			case next.Kind != KindComment && next.ParentID == c.ID:
				got += next.Count
			}
		}
		if got != c.ReplyCount {
			t.Errorf("comment %q: %d replies shown or promised, reply_count %d", c.Body, got, c.ReplyCount)
		}
	}
}

func TestCreateAndCounters(t *testing.T) {
	e := newEnv(t)
	top := e.add(t, nil, "top", 0)
	reply := e.add(t, &top, "reply", 0)
	if top.Depth != 0 || reply.Depth != 1 || *reply.ParentID != top.ID || reply.Author.Username != "author" {
		t.Errorf("top %+v, reply %+v", top, reply)
	}

	var commentCount, replyCount int
	e.db.QueryRow(e.ctx, `SELECT comment_count FROM posts WHERE id = $1`, e.postID).Scan(&commentCount)
	e.db.QueryRow(e.ctx, `SELECT reply_count FROM comments WHERE id = $1`, top.ID).Scan(&replyCount)
	if commentCount != 2 || replyCount != 1 {
		t.Errorf("post comment_count %d, top reply_count %d; want 2, 1", commentCount, replyCount)
	}

	other := e.newPost(t)
	if _, err := e.svc.Create(e.ctx, e.author, other, &top.ID, "x"); !errors.Is(err, ErrParentNotFound) {
		t.Errorf("parent from another post: %v", err)
	}
	e.svc.Delete(e.ctx, reply.ID, e.author)
	if _, err := e.svc.Create(e.ctx, e.author, e.postID, &reply.ID, "x"); !errors.Is(err, ErrParentNotFound) {
		t.Errorf("reply to deleted: %v", err)
	}
	e.db.Exec(e.ctx, `UPDATE posts SET deleted_at = now() WHERE id = $1`, other)
	if _, err := e.svc.Create(e.ctx, e.author, other, nil, "x"); !errors.Is(err, ErrPostNotFound) {
		t.Errorf("deleted post: %v", err)
	}
	var verr *ValidationError
	if _, err := e.svc.Create(e.ctx, e.author, e.postID, nil, "   "); !errors.As(err, &verr) {
		t.Errorf("empty body: %v", err)
	}
	if _, err := NewService(e.db, denyAll{}).Create(e.ctx, e.author, e.postID, nil, "x"); !errors.Is(err, ErrRateLimited) {
		t.Errorf("rate limit: %v", err)
	}
}

func TestEditAndDeleteKeepThread(t *testing.T) {
	e := newEnv(t)
	stranger := testdb.CreateUser(t, e.db, "stranger")
	top := e.add(t, nil, "top", 0)
	e.add(t, &top, "reply", 0)

	edited, err := e.svc.Edit(e.ctx, top.ID, e.author, "правка")
	if err != nil || edited.Body != "правка" || edited.EditedAt == nil {
		t.Errorf("edit: %+v, %v", edited, err)
	}
	if _, err := e.svc.Edit(e.ctx, top.ID, stranger, "x"); !errors.Is(err, ErrForbidden) {
		t.Errorf("stranger edit: %v", err)
	}
	if err := e.svc.Delete(e.ctx, top.ID, stranger); !errors.Is(err, ErrForbidden) {
		t.Errorf("stranger delete: %v", err)
	}
	for range 2 {
		if err := e.svc.Delete(e.ctx, top.ID, e.author); err != nil {
			t.Fatalf("delete: %v", err)
		}
	}
	if _, err := e.svc.Edit(e.ctx, top.ID, e.author, "x"); !errors.Is(err, ErrNotFound) {
		t.Errorf("edit deleted: %v", err)
	}

	page, err := e.svc.Thread(e.ctx, e.postID, Query{Sort: SortBest, Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	tomb := page.Items[0].Comment
	if !tomb.Deleted || tomb.Body != "" || tomb.Author != nil {
		t.Errorf("tombstone leaks: %+v", tomb)
	}
	if got := layout(page.Items); got != "@0 reply@1" {
		t.Errorf("layout = %q", got)
	}
}

func TestThreadOrder(t *testing.T) {
	e := newEnv(t)
	a := e.add(t, nil, "A", 5)
	e.add(t, &a, "A1", 1)
	a2 := e.add(t, &a, "A2", 3)
	e.add(t, &a2, "A2a", 0)
	e.add(t, nil, "B", 9)
	e.add(t, nil, "C", 5) // ties with A: the older A goes first

	tests := []struct {
		sort Sort
		want string
	}{
		{SortBest, "B@0 A@0 A2@1 A2a@2 A1@1 C@0"},
		{SortNew, "C@0 B@0 A@0 A2@1 A2a@2 A1@1"},
	}
	for _, tt := range tests {
		page, err := e.svc.Thread(e.ctx, e.postID, Query{Sort: tt.sort, Limit: 10})
		if err != nil {
			t.Fatal(err)
		}
		if got := layout(page.Items); got != tt.want {
			t.Errorf("%s:\n got  %s\n want %s", tt.sort, got, tt.want)
		}
		checkCounts(t, page.Items)
	}
}

func TestMoreStubContinuesExactly(t *testing.T) {
	e := newEnv(t)
	p := e.add(t, nil, "P", 0)
	for i := range 12 {
		e.add(t, &p, fmt.Sprintf("r%02d", i), i) // r11 is the best
	}

	page, err := e.svc.Thread(e.ctx, e.postID, Query{Sort: SortBest, Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	want := "P@0 r11@1 r10@1 r09@1 r08@1 r07@1 r06@1 r05@1 r04@1 +more(4)@1"
	if got := layout(page.Items); got != want {
		t.Fatalf("thread:\n got  %s\n want %s", got, want)
	}
	checkCounts(t, page.Items)

	stub := page.Items[len(page.Items)-1]
	more, err := e.svc.Replies(e.ctx, stub.ParentID, Query{Sort: SortBest, After: stub.After, Limit: 20})
	if err != nil {
		t.Fatal(err)
	}
	if got := layout(more.Items); got != "r03@1 r02@1 r01@1 r00@1" || more.Next != nil {
		t.Errorf("more: %s (next %v)", got, more.Next)
	}
}

func TestContinueAtMaxDepth(t *testing.T) {
	e := newEnv(t)
	var chain []Comment
	var parent *Comment
	for i := range 8 {
		c := e.add(t, parent, fmt.Sprintf("d%d", i), 0)
		chain = append(chain, c)
		parent = &chain[len(chain)-1]
	}

	page, err := e.svc.Thread(e.ctx, e.postID, Query{Sort: SortBest, Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if got := layout(page.Items); got != "d0@0 d1@1 d2@2 d3@3 d4@4 d5@5 +continue(1)@6" {
		t.Fatalf("thread: %s", got)
	}
	checkCounts(t, page.Items)

	stub := page.Items[len(page.Items)-1]
	if stub.ParentID != chain[5].ID || stub.After != nil {
		t.Errorf("continue stub: %+v", stub)
	}
	rest, err := e.svc.Replies(e.ctx, stub.ParentID, Query{Sort: SortBest, Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if got := layout(rest.Items); got != "d6@6 d7@7" {
		t.Errorf("continued thread: %s", got)
	}
}

func TestTopLevelPagination(t *testing.T) {
	e := newEnv(t)
	for i, score := range []int{3, 1, 3, 2, 3} { // three-way tie on 3
		e.add(t, nil, fmt.Sprintf("c%d", i), score)
	}
	for _, tt := range []struct {
		sort Sort
		want string
	}{
		{SortBest, "c0@0 c2@0 c4@0 c3@0 c1@0"},
		{SortNew, "c4@0 c3@0 c2@0 c1@0 c0@0"},
	} {
		var all []string
		q := Query{Sort: tt.sort, Limit: 2}
		for range 10 {
			page, err := e.svc.Thread(e.ctx, e.postID, q)
			if err != nil {
				t.Fatal(err)
			}
			all = append(all, layout(page.Items))
			if page.Next == nil {
				break
			}
			q.After = page.Next
		}
		if got := strings.Join(all, " "); got != tt.want {
			t.Errorf("%s pages: %s, want %s", tt.sort, got, tt.want)
		}
	}
}

func TestHugeThreadIsCappedButConsistent(t *testing.T) {
	e := newEnv(t)
	// 30 top-level comments × 10 replies × 10 replies = 3330 comments,
	// inserted in bulk (the trigger still sets depth and counters).
	for _, sql := range []string{
		`INSERT INTO comments (post_id, author_id, body) SELECT $1, $2, 't' || g FROM generate_series(1, 30) g`,
		`INSERT INTO comments (post_id, parent_id, author_id, body)
		 SELECT $1, p.id, $2, 'r' FROM comments p, generate_series(1, 10) WHERE p.post_id = $1 AND p.depth = 0`,
		`INSERT INTO comments (post_id, parent_id, author_id, body)
		 SELECT $1, p.id, $2, 'rr' FROM comments p, generate_series(1, 10) WHERE p.post_id = $1 AND p.depth = 1`,
	} {
		if _, err := e.db.Exec(e.ctx, sql, e.postID, e.author); err != nil {
			t.Fatal(err)
		}
	}

	page, err := e.svc.Thread(e.ctx, e.postID, Query{Sort: SortBest, Limit: 30})
	if err != nil {
		t.Fatal(err)
	}
	comments := 0
	for _, it := range page.Items {
		if it.Kind == KindComment {
			comments++
		}
	}
	if comments != 30+maxTreeRows {
		t.Errorf("%d comments in the response, want the page (30) + the cap (%d)", comments, maxTreeRows)
	}
	checkCounts(t, page.Items)
}

func TestCommentVotes(t *testing.T) {
	e := newEnv(t)
	voter := testdb.CreateUser(t, e.db, "voter")
	c := e.add(t, nil, "c", 0)
	votes := vote.NewService(e.db, allowAll{})

	if res, err := votes.VoteComment(e.ctx, voter, c.ID, 1); err != nil || res.Score != 1 {
		t.Fatalf("vote: %+v, %v", res, err)
	}
	if _, err := vote.Flush(e.ctx, e.db, 100); err != nil {
		t.Fatal(err)
	}

	page, _ := e.svc.Thread(e.ctx, e.postID, Query{Sort: SortBest, Limit: 10, Viewer: voter})
	got := page.Items[0].Comment
	if got.Score != 1 || got.MyVote != 1 {
		t.Errorf("after flush: score %d my_vote %d", got.Score, got.MyVote)
	}
	var karma int
	e.db.QueryRow(e.ctx, `SELECT comment_karma FROM users WHERE id = $1`, e.author).Scan(&karma)
	if karma != 1 {
		t.Errorf("comment_karma = %d, want 1", karma)
	}
}

func TestNotFound(t *testing.T) {
	e := newEnv(t)
	if _, err := e.svc.Replies(e.ctx, 999999, Query{Sort: SortBest, Limit: 10}); !errors.Is(err, ErrNotFound) {
		t.Errorf("replies of unknown: %v", err)
	}
	e.db.Exec(e.ctx, `UPDATE posts SET deleted_at = now() WHERE id = $1`, e.postID)
	if _, err := e.svc.Thread(e.ctx, e.postID, Query{Sort: SortBest, Limit: 10}); !errors.Is(err, ErrPostNotFound) {
		t.Errorf("thread of deleted post: %v", err)
	}
}
