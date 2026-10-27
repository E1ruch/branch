// Package comment owns threaded comments: writing them and loading a thread
// as a flat, display-ordered list.
package comment

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
)

var (
	ErrNotFound       = errors.New("comment: not found")
	ErrPostNotFound   = errors.New("comment: post not found")
	ErrParentNotFound = errors.New("comment: parent comment not found")
	ErrForbidden      = errors.New("comment: forbidden")
	ErrRateLimited    = errors.New("comment: too many comments")
)

type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string { return e.Field + ": " + e.Message }

type Limiter interface {
	Allow(ctx context.Context, key string, limit int, window time.Duration) (bool, error)
}

type Comment struct {
	ID         int64
	PostID     int64
	ParentID   *int64
	Depth      int // absolute: 0 = top level
	Body       string
	Deleted    bool // a tombstone: body and author hidden, replies kept
	Author     *AuthorRef
	Score      int
	MyVote     int
	ReplyCount int // direct replies, including deleted ones
	CreatedAt  time.Time
	EditedAt   *time.Time
}

type AuthorRef struct {
	ID          int64
	Username    string
	DisplayName *string
}

const (
	maxBody = 10000

	commentsPerWindow = 20
	commentsWindow    = 10 * time.Minute
)

type Service struct {
	db      *pgxpool.Pool
	limiter Limiter
	now     func() time.Time
}

func NewService(db *pgxpool.Pool, limiter Limiter) *Service {
	return &Service{db: db, limiter: limiter, now: time.Now}
}

// project turns raw comment rows from `from` (aliased t) into Comment
// columns. $1 is always the viewer. Deleted comments lose body and author
// here, in one place, so no endpoint can leak them.
func project(from string) string {
	return `
	SELECT t.id, t.post_id, t.parent_id, t.depth,
	       CASE WHEN t.deleted_at IS NULL THEN t.body ELSE '' END, t.deleted_at IS NOT NULL,
	       t.score, COALESCE(v.value, 0), t.reply_count, t.created_at, t.edited_at,
	       u.id, u.username, u.display_name
	FROM ` + from + ` t
	LEFT JOIN users u ON u.id = t.author_id AND u.deleted_at IS NULL AND t.deleted_at IS NULL
	LEFT JOIN comment_votes v ON v.comment_id = t.id AND v.user_id = $1`
}

func scan(row pgx.Row) (Comment, error) {
	var (
		c           Comment
		authorID    *int64
		username    *string
		displayName *string
	)
	err := row.Scan(&c.ID, &c.PostID, &c.ParentID, &c.Depth, &c.Body, &c.Deleted,
		&c.Score, &c.MyVote, &c.ReplyCount, &c.CreatedAt, &c.EditedAt,
		&authorID, &username, &displayName)
	if errors.Is(err, pgx.ErrNoRows) {
		return Comment{}, ErrNotFound
	}
	if err != nil {
		return Comment{}, err
	}
	if authorID != nil {
		c.Author = &AuthorRef{ID: *authorID, Username: *username, DisplayName: displayName}
	}
	return c, nil
}

func (s *Service) Get(ctx context.Context, id, viewer int64) (Comment, error) {
	return scan(s.db.QueryRow(ctx, project("comments")+` WHERE t.id = $2`, viewer, id))
}

// Create adds a top-level comment (parentID nil) or a reply. The database
// trigger derives depth and root and rejects a parent from another post.
func (s *Service) Create(ctx context.Context, authorID, postID int64, parentID *int64, body string) (Comment, error) {
	body = strings.TrimSpace(body)
	if n := utf8.RuneCountInString(body); n < 1 || n > maxBody {
		return Comment{}, &ValidationError{"body", fmt.Sprintf("length must be 1-%d characters", maxBody)}
	}

	var exists bool
	if err := s.db.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM posts WHERE id = $1 AND deleted_at IS NULL)`, postID).Scan(&exists); err != nil {
		return Comment{}, err
	}
	if !exists {
		return Comment{}, ErrPostNotFound
	}
	if parentID != nil {
		// No replies to deleted comments: the conversation there is over.
		if err := s.db.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM comments WHERE id = $1 AND post_id = $2 AND deleted_at IS NULL)`,
			*parentID, postID).Scan(&exists); err != nil {
			return Comment{}, err
		}
		if !exists {
			return Comment{}, ErrParentNotFound
		}
	}

	ok, err := s.limiter.Allow(ctx, "comment:"+strconv.FormatInt(authorID, 10), commentsPerWindow, commentsWindow)
	if err != nil {
		return Comment{}, err
	}
	if !ok {
		return Comment{}, ErrRateLimited
	}

	var id int64
	if err := s.db.QueryRow(ctx, `
		INSERT INTO comments (post_id, parent_id, author_id, body, created_at)
		VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		postID, parentID, authorID, body, s.now()).Scan(&id); err != nil {
		return Comment{}, err
	}
	return s.Get(ctx, id, authorID)
}

func (s *Service) Edit(ctx context.Context, id, userID int64, body string) (Comment, error) {
	body = strings.TrimSpace(body)
	if n := utf8.RuneCountInString(body); n < 1 || n > maxBody {
		return Comment{}, &ValidationError{"body", fmt.Sprintf("length must be 1-%d characters", maxBody)}
	}
	if err := s.checkAuthor(ctx, id, userID, false); err != nil {
		return Comment{}, err
	}
	if _, err := s.db.Exec(ctx,
		`UPDATE comments SET body = $2, edited_at = $3 WHERE id = $1 AND deleted_at IS NULL`,
		id, body, s.now()); err != nil {
		return Comment{}, err
	}
	return s.Get(ctx, id, userID)
}

// Delete turns the comment into a tombstone; its replies stay readable.
// Deleting your own deleted comment again succeeds, so retries are safe.
func (s *Service) Delete(ctx context.Context, id, userID int64) error {
	if err := s.checkAuthor(ctx, id, userID, true); err != nil {
		return err
	}
	_, err := s.db.Exec(ctx,
		`UPDATE comments SET deleted_at = $2 WHERE id = $1 AND deleted_at IS NULL`, id, s.now())
	return err
}

func (s *Service) checkAuthor(ctx context.Context, id, userID int64, allowDeleted bool) error {
	var (
		authorID *int64
		deleted  bool
	)
	err := s.db.QueryRow(ctx,
		`SELECT author_id, deleted_at IS NOT NULL FROM comments WHERE id = $1`, id).Scan(&authorID, &deleted)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && deleted && !allowDeleted) {
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
