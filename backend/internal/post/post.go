// Package post owns posts and the feeds built from them.
package post

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/ranking"
)

var (
	ErrNotFound          = errors.New("post: not found")
	ErrCommunityNotFound = errors.New("post: community not found")
	ErrForbidden         = errors.New("post: forbidden")
	ErrRateLimited       = errors.New("post: too many posts")
	// The post to continue is gone (or never was).
	ErrStoryNotFound = errors.New("post: the post to continue is not found")
	// Only a post's author may add parts to its story.
	ErrNotStoryAuthor = errors.New("post: only the author can continue the story")
)

type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string { return e.Field + ": " + e.Message }

// Limiter caps how often a user may post. Allow reports whether one more
// event for key fits in limit per window.
type Limiter interface {
	Allow(ctx context.Context, key string, limit int, window time.Duration) (bool, error)
}

type Post struct {
	ID            int64
	Title         string
	Body          string
	BodyTruncated bool // feeds carry a preview; GET /posts/{id} has the full body
	IsNSFW        bool
	Score         int
	CommentCount  int
	MyVote        int // the viewer's vote: -1, 0 or 1
	HotRank       float64
	CreatedAt     time.Time
	EditedAt      *time.Time

	Community CommunityRef
	Author    *AuthorRef // nil when the account is deleted
	Story     *StoryRef  // nil when the post is not part of a story
}

// StoryRef places a post in its story. Part and Parts count live parts
// only, so deleting part 2 of 3 makes part 3 "Часть 2 из 2".
type StoryRef struct {
	ID    int64
	Part  int
	Parts int
}

type CommunityRef struct {
	ID    int64
	Slug  string
	Title string
}

type AuthorRef struct {
	ID          int64
	Username    string
	DisplayName *string
}

const (
	maxTitle   = 300
	maxBody    = 40000
	previewLen = 600

	postsPerHour = 10
)

type Service struct {
	db      *pgxpool.Pool
	limiter Limiter
	now     func() time.Time
}

func NewService(db *pgxpool.Pool, limiter Limiter) *Service {
	return &Service{db: db, limiter: limiter, now: time.Now}
}

// selectPost is shared by single-post reads and feeds. Feeds get a preview
// of the body: cells show a few lines, and shipping up to 40k characters per
// post would bloat every page and its decoding on the phone.
//
// $1 is always the viewer (0 = anonymous, matches no vote). The vote comes
// from the (user_id, post_id) primary key in the same query, so a page of 25
// posts with the viewer's votes is still one round trip.
func selectPost(preview bool) string {
	body := "p.body, false"
	if preview {
		n := strconv.Itoa(previewLen)
		body = "left(p.body, " + n + "), char_length(p.body) > " + n
	}
	return `
	SELECT p.id, p.title, ` + body + `,
	       p.is_nsfw, p.score, p.comment_count, COALESCE(v.value, 0), p.hot_rank, p.created_at, p.edited_at,
	       c.id, c.slug, c.title,
	       u.id, u.username, u.display_name,
	       p.story_id, st.part, st.parts
	FROM %s p
	JOIN communities c ON c.id = p.community_id
	LEFT JOIN users u ON u.id = p.author_id AND u.deleted_at IS NULL
	LEFT JOIN post_votes v ON v.post_id = p.id AND v.user_id = $1
	LEFT JOIN LATERAL (
		SELECT count(*) FILTER (WHERE sp.story_part <= p.story_part) AS part, count(*) AS parts
		FROM posts sp WHERE sp.story_id = p.story_id AND sp.deleted_at IS NULL
	) st ON p.story_id IS NOT NULL`
}

func scan(row pgx.Row) (Post, error) {
	var (
		p           Post
		authorID    *int64
		username    *string
		displayName *string
		storyID     *int64
		part, parts *int
	)
	err := row.Scan(&p.ID, &p.Title, &p.Body, &p.BodyTruncated,
		&p.IsNSFW, &p.Score, &p.CommentCount, &p.MyVote, &p.HotRank, &p.CreatedAt, &p.EditedAt,
		&p.Community.ID, &p.Community.Slug, &p.Community.Title,
		&authorID, &username, &displayName,
		&storyID, &part, &parts)
	if errors.Is(err, pgx.ErrNoRows) {
		return Post{}, ErrNotFound
	}
	if err != nil {
		return Post{}, err
	}
	if authorID != nil {
		p.Author = &AuthorRef{ID: *authorID, Username: *username, DisplayName: displayName}
	}
	if storyID != nil && part != nil && parts != nil {
		p.Story = &StoryRef{ID: *storyID, Part: *part, Parts: *parts}
	}
	return p, nil
}

// Get returns the post as viewer sees it (viewer 0 = anonymous).
func (s *Service) Get(ctx context.Context, id, viewer int64) (Post, error) {
	return scan(s.db.QueryRow(ctx,
		fmt.Sprintf(selectPost(false), "posts")+` WHERE p.id = $2 AND p.deleted_at IS NULL`, viewer, id))
}

type CreateInput struct {
	Title  string
	Body   string
	IsNSFW bool
	// The author's post this one continues: the new post becomes the last
	// part of its story (a story is started if there is none yet).
	ContinuesPostID *int64
}

func (s *Service) Create(ctx context.Context, authorID int64, communitySlug string, in CreateInput) (Post, error) {
	in.Title = strings.TrimSpace(in.Title)
	in.Body = strings.TrimSpace(in.Body)
	if err := validateLen("title", in.Title, 1, maxTitle); err != nil {
		return Post{}, err
	}
	if err := validateLen("body", in.Body, 0, maxBody); err != nil {
		return Post{}, err
	}

	var communityID int64
	var communityNSFW bool
	err := s.db.QueryRow(ctx, `SELECT id, is_nsfw FROM communities WHERE slug = $1`, communitySlug).
		Scan(&communityID, &communityNSFW)
	if errors.Is(err, pgx.ErrNoRows) {
		return Post{}, ErrCommunityNotFound
	}
	if err != nil {
		return Post{}, err
	}

	ok, err := s.limiter.Allow(ctx, "post:"+strconv.FormatInt(authorID, 10), postsPerHour, time.Hour)
	if err != nil {
		return Post{}, err
	}
	if !ok {
		return Post{}, ErrRateLimited
	}

	now := s.now()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Post{}, err
	}
	defer tx.Rollback(ctx)

	var storyID *int64
	var part *int
	if in.ContinuesPostID != nil {
		sid, n, err := appendPart(ctx, tx, authorID, *in.ContinuesPostID, now)
		if err != nil {
			return Post{}, err
		}
		storyID, part = &sid, &n
	}

	var id int64
	if err := tx.QueryRow(ctx, `
		INSERT INTO posts (community_id, author_id, title, body, is_nsfw, hot_rank, created_at, story_id, story_part)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		RETURNING id`,
		communityID, authorID, in.Title, in.Body,
		in.IsNSFW || communityNSFW, // a post in an NSFW community is NSFW
		ranking.Hot(0, 0, now), now, storyID, part,
	).Scan(&id); err != nil {
		return Post{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Post{}, err
	}
	return s.Get(ctx, id, authorID)
}

// appendPart finds the story a new post joins and its part number: the
// last part of prevID's story, or part 2 of a story started from prevID.
// Row locks (the post, then the story) serialize two parts published at
// once, so numbers never collide.
func appendPart(ctx context.Context, tx pgx.Tx, authorID, prevID int64, now time.Time) (int64, int, error) {
	var owner, storyID *int64
	err := tx.QueryRow(ctx,
		`SELECT author_id, story_id FROM posts WHERE id = $1 AND deleted_at IS NULL FOR UPDATE`, prevID,
	).Scan(&owner, &storyID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, 0, ErrStoryNotFound
	}
	if err != nil {
		return 0, 0, err
	}
	if owner == nil || *owner != authorID {
		return 0, 0, ErrNotStoryAuthor
	}

	if storyID == nil {
		var id int64
		if err := tx.QueryRow(ctx,
			`INSERT INTO stories (author_id, created_at) VALUES ($1, $2) RETURNING id`, authorID, now,
		).Scan(&id); err != nil {
			return 0, 0, err
		}
		if _, err := tx.Exec(ctx, `UPDATE posts SET story_id = $1, story_part = 1 WHERE id = $2`, id, prevID); err != nil {
			return 0, 0, err
		}
		return id, 2, nil
	}

	if _, err := tx.Exec(ctx, `SELECT 1 FROM stories WHERE id = $1 FOR UPDATE`, *storyID); err != nil {
		return 0, 0, err
	}
	var next int
	if err := tx.QueryRow(ctx,
		`SELECT max(story_part) + 1 FROM posts WHERE story_id = $1`, *storyID,
	).Scan(&next); err != nil {
		return 0, 0, err
	}
	return *storyID, next, nil
}

// StoryPart is one entry of a story's table of contents.
type StoryPart struct {
	PostID    int64
	Title     string
	Part      int // among live parts, from 1
	CreatedAt time.Time
}

// StoryParts lists the story of postID in order, deleted parts left out.
// A post outside any story has an empty list.
func (s *Service) StoryParts(ctx context.Context, postID int64) ([]StoryPart, error) {
	var storyID *int64
	err := s.db.QueryRow(ctx,
		`SELECT story_id FROM posts WHERE id = $1 AND deleted_at IS NULL`, postID).Scan(&storyID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	out := []StoryPart{}
	if storyID == nil {
		return out, nil
	}
	rows, err := s.db.Query(ctx, `
		SELECT id, title, row_number() OVER (ORDER BY story_part), created_at
		FROM posts WHERE story_id = $1 AND deleted_at IS NULL
		ORDER BY story_part`, *storyID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var p StoryPart
		if err := rows.Scan(&p.PostID, &p.Title, &p.Part, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Edit replaces the body. Titles are immutable: votes and comments were given
// to the headline people saw, so changing it would rewrite the context.
func (s *Service) Edit(ctx context.Context, id, userID int64, body string) (Post, error) {
	body = strings.TrimSpace(body)
	if err := validateLen("body", body, 0, maxBody); err != nil {
		return Post{}, err
	}
	if err := s.checkAuthor(ctx, id, userID); err != nil {
		return Post{}, err
	}
	if _, err := s.db.Exec(ctx,
		`UPDATE posts SET body = $2, edited_at = $3 WHERE id = $1 AND deleted_at IS NULL`,
		id, body, s.now()); err != nil {
		return Post{}, err
	}
	return s.Get(ctx, id, userID)
}

// Delete hides the post (soft delete keeps comment threads intact).
// Deleting an already deleted post of your own succeeds, so retries are safe.
func (s *Service) Delete(ctx context.Context, id, userID int64) error {
	var authorID *int64
	err := s.db.QueryRow(ctx, `SELECT author_id FROM posts WHERE id = $1`, id).Scan(&authorID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if authorID == nil || *authorID != userID {
		return ErrForbidden
	}
	_, err = s.db.Exec(ctx,
		`UPDATE posts SET deleted_at = $2 WHERE id = $1 AND deleted_at IS NULL`, id, s.now())
	return err
}

func (s *Service) checkAuthor(ctx context.Context, id, userID int64) error {
	var authorID *int64
	err := s.db.QueryRow(ctx,
		`SELECT author_id FROM posts WHERE id = $1 AND deleted_at IS NULL`, id).Scan(&authorID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if authorID == nil || *authorID != userID {
		return ErrForbidden
	}
	return nil
}

func validateLen(field, s string, min, max int) error {
	n := utf8.RuneCountInString(s)
	if n < min || n > max {
		return &ValidationError{field, fmt.Sprintf("length must be %d-%d characters", min, max)}
	}
	return nil
}
