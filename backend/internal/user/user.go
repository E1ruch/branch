// Package user owns user profiles.
package user

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrNotFound = errors.New("user: not found")

type User struct {
	ID           int64
	Username     string
	DisplayName  *string
	PostKarma    int
	CommentKarma int
	CreatedAt    time.Time
}

// Columns is the select list matching Scan, for queries in other packages
// that return users (sign-up, for one).
const Columns = "id, username, display_name, post_karma, comment_karma, created_at"

func Scan(row pgx.Row) (User, error) {
	var u User
	err := row.Scan(&u.ID, &u.Username, &u.DisplayName, &u.PostKarma, &u.CommentKarma, &u.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	return u, err
}

type Store struct {
	db *pgxpool.Pool
}

func NewStore(db *pgxpool.Pool) *Store {
	return &Store{db: db}
}

func (s *Store) Get(ctx context.Context, id int64) (User, error) {
	return Scan(s.db.QueryRow(ctx,
		`SELECT `+Columns+` FROM users WHERE id = $1 AND deleted_at IS NULL`, id))
}
