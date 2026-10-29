// Package user owns user profiles: reading, editing and deleting accounts.
package user

import (
	"context"
	"errors"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrNotFound              = errors.New("user: not found")
	ErrUsernameTaken         = errors.New("user: username taken")
	ErrUsernameChangeTooSoon = errors.New("user: username changed recently")
	ErrFollowSelf            = errors.New("user: cannot follow yourself")
)

type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string { return e.Field + ": " + e.Message }

type User struct {
	ID           int64
	Username     string
	DisplayName  *string
	Bio          *string
	PostKarma    int
	CommentKarma int
	CreatedAt    time.Time

	PostsCount     int
	FollowersCount int
	FollowingCount int

	// When the user may pick a new username; nil means now.
	UsernameChangeableAt *time.Time
}

const (
	usernameCooldown = 30 * 24 * time.Hour
	maxDisplayName   = 48
	maxBio           = 300
)

// Columns is the select list matching Scan, for queries in other packages
// that return users (sign-up, for one).
const Columns = `id, username, display_name, bio, post_karma, comment_karma, created_at,
	posts_count, followers_count, following_count,
	username_changed_at + interval '30 days'`

func Scan(row pgx.Row) (User, error) {
	return scan(row)
}

// scan reads Columns, then the extra destinations a query selects after them.
func scan(row pgx.Row, extra ...any) (User, error) {
	var u User
	err := row.Scan(append([]any{&u.ID, &u.Username, &u.DisplayName, &u.Bio, &u.PostKarma, &u.CommentKarma,
		&u.CreatedAt, &u.PostsCount, &u.FollowersCount, &u.FollowingCount, &u.UsernameChangeableAt}, extra...)...)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	return u, err
}

// Same rule as the users.username CHECK constraint.
var usernameRe = regexp.MustCompile(`^[A-Za-z0-9_]{3,24}$`)

// Names people would take for staff or for the system itself.
var reservedUsernames = map[string]bool{
	"admin": true, "administrator": true, "moderator": true, "mod": true,
	"support": true, "help": true, "official": true, "vetka": true, "system": true,
	"root": true, "me": true, "null": true, "undefined": true, "anonymous": true,
}

// ValidateUsername checks a name a person chose or a provider suggested.
// "deleted_*" is how deleted accounts are renamed, so nobody may take it.
func ValidateUsername(name string) error {
	if !usernameRe.MatchString(name) {
		return &ValidationError{"username", "3-24 latin letters, digits or underscores"}
	}
	lower := strings.ToLower(name)
	if reservedUsernames[lower] || strings.HasPrefix(lower, "deleted_") {
		return &ValidationError{"username", "this name is reserved"}
	}
	return nil
}

type Store struct {
	db  *pgxpool.Pool
	now func() time.Time
}

func NewStore(db *pgxpool.Pool) *Store {
	return &Store{db: db, now: time.Now}
}

func (s *Store) Get(ctx context.Context, id int64) (User, error) {
	return Scan(s.db.QueryRow(ctx,
		`SELECT `+Columns+` FROM users WHERE id = $1 AND deleted_at IS NULL`, id))
}

func (s *Store) GetByUsername(ctx context.Context, username string) (User, error) {
	return Scan(s.db.QueryRow(ctx,
		`SELECT `+Columns+` FROM users WHERE username = $1 AND deleted_at IS NULL`, username))
}

// MinSearchLen, as for posts: two letters match a large part of everyone.
const MinSearchLen = 3

// Search finds people: the exact username, then usernames that start with
// the query, then display names that contain it.
//
// Each part is its own query with a plan that stays cheap however many
// people match (measured on 200k users: well under a millisecond each):
//   - usernames by their start (people type "@ив…"), read in the order of
//     users_username_prefix_idx, so the scan stops at the limit;
//   - display names anywhere through the trigram index, the first 500
//     matches only, the more active of them first. Ordering all matches by
//     karma (or closeness) made Postgres score and sort every "Иван".
func (s *Store) Search(ctx context.Context, query string, limit int) ([]User, error) {
	query = strings.TrimSpace(query)
	if utf8.RuneCountInString(query) < MinSearchLen {
		return []User{}, nil
	}
	out := []User{}
	seen := map[int64]bool{}
	add := func(rows pgx.Rows, err error) error {
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			u, err := Scan(rows)
			if err != nil {
				return err
			}
			if !seen[u.ID] && len(out) < limit {
				seen[u.ID] = true
				out = append(out, u)
			}
		}
		return rows.Err()
	}

	escaped := likeEscaper.Replace(query)
	if err := add(s.db.Query(ctx, `SELECT `+Columns+` FROM users WHERE username = $1 AND deleted_at IS NULL`, query)); err != nil {
		return nil, err
	}
	if err := add(s.db.Query(ctx, `SELECT `+Columns+` FROM users
		WHERE deleted_at IS NULL AND lower(username::text) LIKE $1
		ORDER BY lower(username::text) USING ~<~
		LIMIT $2`, strings.ToLower(escaped)+"%", limit)); err != nil {
		return nil, err
	}
	if len(out) < limit {
		// MATERIALIZED keeps the 500 apart: inlined, Postgres would merge the
		// limits and walk users by karma looking for a match.
		if err := add(s.db.Query(ctx, `
			WITH matches AS MATERIALIZED (
				SELECT id, post_karma + comment_karma AS karma FROM users
				WHERE deleted_at IS NULL AND display_name ILIKE $1
				LIMIT 500
			)
			SELECT `+Columns+` FROM users JOIN matches USING (id)
			ORDER BY matches.karma DESC, id LIMIT $2`, "%"+escaped+"%", limit)); err != nil {
			return nil, err
		}
	}
	return out, nil
}

var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// UsernameAvailable powers the live check in the onboarding text field.
// The error is the reason a name cannot be used (validation or taken).
func (s *Store) UsernameAvailable(ctx context.Context, name string) error {
	if err := ValidateUsername(name); err != nil {
		return err
	}
	var taken bool
	if err := s.db.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM users WHERE username = $1)`, name).Scan(&taken); err != nil {
		return err
	}
	if taken {
		return ErrUsernameTaken
	}
	return nil
}

// UpdateInput changes only the non-nil fields. An empty display name or bio
// clears it.
type UpdateInput struct {
	Username    *string
	DisplayName *string
	Bio         *string
}

func (s *Store) Update(ctx context.Context, id int64, in UpdateInput) (User, error) {
	displayName, err := optionalText("display_name", in.DisplayName, maxDisplayName)
	if err != nil {
		return User{}, err
	}
	bio, err := optionalText("bio", in.Bio, maxBio)
	if err != nil {
		return User{}, err
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return User{}, err
	}
	defer tx.Rollback(ctx)

	current, err := Scan(tx.QueryRow(ctx,
		`SELECT `+Columns+` FROM users WHERE id = $1 AND deleted_at IS NULL FOR UPDATE`, id))
	if err != nil {
		return User{}, err
	}

	now := s.now()
	// Changing only the letter case is a fix, not a new name: no cooldown.
	if in.Username != nil && *in.Username != current.Username {
		if err := ValidateUsername(*in.Username); err != nil {
			return User{}, err
		}
		if !strings.EqualFold(*in.Username, current.Username) &&
			current.UsernameChangeableAt != nil && now.Before(*current.UsernameChangeableAt) {
			return User{}, ErrUsernameChangeTooSoon
		}
		tag, err := tx.Exec(ctx, `
			UPDATE users SET username = $2,
				username_changed_at = CASE WHEN lower($2) = lower(username) THEN username_changed_at ELSE $3 END
			WHERE id = $1
			  AND NOT EXISTS (SELECT 1 FROM users WHERE username = $2 AND id <> $1)`,
			id, *in.Username, now)
		if isUniqueViolation(err) || (err == nil && tag.RowsAffected() == 0) {
			return User{}, ErrUsernameTaken
		}
		if err != nil {
			return User{}, err
		}
	}

	if in.DisplayName != nil || in.Bio != nil {
		if _, err := tx.Exec(ctx, `
			UPDATE users SET
				display_name = CASE WHEN $2 THEN $3 ELSE display_name END,
				bio          = CASE WHEN $4 THEN $5 ELSE bio END
			WHERE id = $1`,
			id, in.DisplayName != nil, displayName, in.Bio != nil, bio); err != nil {
			return User{}, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return User{}, err
	}
	return s.Get(ctx, id)
}

// Follow and Unfollow set the desired state rather than toggle it, as
// community subscriptions do, so retries and double taps are harmless. Both
// return the fresh profile for the client to reconcile its optimistic counter.
func (s *Store) Follow(ctx context.Context, followerID int64, username string) (User, error) {
	u, err := s.GetByUsername(ctx, username)
	if err != nil {
		return User{}, err
	}
	if u.ID == followerID {
		return User{}, ErrFollowSelf
	}
	if _, err := s.db.Exec(ctx, `
		INSERT INTO user_follows (follower_id, followee_id) VALUES ($1, $2)
		ON CONFLICT DO NOTHING`, followerID, u.ID); err != nil {
		return User{}, err
	}
	return s.Get(ctx, u.ID)
}

func (s *Store) Unfollow(ctx context.Context, followerID int64, username string) (User, error) {
	u, err := s.GetByUsername(ctx, username)
	if err != nil {
		return User{}, err
	}
	if _, err := s.db.Exec(ctx,
		`DELETE FROM user_follows WHERE follower_id = $1 AND followee_id = $2`, followerID, u.ID); err != nil {
		return User{}, err
	}
	return s.Get(ctx, u.ID)
}

// IsFollowing is false for signed-out viewers (0) and for yourself.
func (s *Store) IsFollowing(ctx context.Context, followerID, followeeID int64) (bool, error) {
	if followerID == 0 || followerID == followeeID {
		return false, nil
	}
	var ok bool
	err := s.db.QueryRow(ctx, `SELECT EXISTS (
		SELECT 1 FROM user_follows WHERE follower_id = $1 AND followee_id = $2)`, followerID, followeeID).Scan(&ok)
	return ok, err
}

// Listed is a person in someone's followers or following list.
type Listed struct {
	User
	// Whether the viewer follows them, for the button in the row.
	IsFollowing bool
	// When the follow in this list began: the list's order and cursor.
	FollowedAt time.Time
}

// FollowCursor is the last row of the previous page.
type FollowCursor struct {
	At time.Time `json:"t"`
	ID int64     `json:"id"`
}

// Followers lists who follows userID, the latest first.
func (s *Store) Followers(ctx context.Context, userID, viewer int64, after *FollowCursor, limit int) ([]Listed, error) {
	return s.followList(ctx, "follower_id", "followee_id", userID, viewer, after, limit)
}

// Following lists whom userID follows, the latest first.
func (s *Store) Following(ctx context.Context, userID, viewer int64, after *FollowCursor, limit int) ([]Listed, error) {
	return s.followList(ctx, "followee_id", "follower_id", userID, viewer, after, limit)
}

// followList pages user_follows by (created_at, other side's id) on the
// index for `owner`, then joins only that page with users. Deleted
// accounts have no follows left, so pages are full.
func (s *Store) followList(ctx context.Context, listed, owner string, userID, viewer int64,
	after *FollowCursor, limit int) ([]Listed, error) {
	cur := FollowCursor{At: time.Now().Add(time.Hour), ID: math.MaxInt64}
	if after != nil {
		cur = *after
	}
	rows, err := s.db.Query(ctx, `
		WITH page AS (
			SELECT `+listed+` AS id, created_at AS followed_at FROM user_follows
			WHERE `+owner+` = $1 AND (created_at, `+listed+`) < ($2, $3)
			ORDER BY created_at DESC, `+listed+` DESC
			LIMIT $4
		)
		SELECT `+Columns+`, page.followed_at,
			EXISTS (SELECT 1 FROM user_follows v WHERE v.follower_id = $5 AND v.followee_id = users.id)
		FROM users JOIN page USING (id)
		WHERE deleted_at IS NULL
		ORDER BY page.followed_at DESC, id DESC`, userID, cur.At, cur.ID, limit, viewer)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Listed{}
	for rows.Next() {
		var l Listed
		l.User, err = scan(rows, &l.FollowedAt, &l.IsFollowing)
		if err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// Delete closes the account, as App Store rules require the app to offer.
//
// Posts and comments stay (threads would break otherwise) but lose their
// author everywhere, since every read joins users with deleted_at IS NULL.
// The username is freed, sign-in identities and the password are dropped
// (signing in again creates a fresh account), all sessions are revoked, and subscriptions go
// so community counters stay honest.
func (s *Store) Delete(ctx context.Context, id int64) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	now := s.now()
	tag, err := tx.Exec(ctx, `
		UPDATE users SET deleted_at = $2, username = 'deleted_' || id,
			display_name = NULL, bio = NULL, avatar_key = NULL
		WHERE id = $1 AND deleted_at IS NULL`, id, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	for _, sql := range []string{
		`DELETE FROM auth_identities WHERE user_id = $1`,
		`DELETE FROM password_credentials WHERE user_id = $1`,
		`DELETE FROM community_members WHERE user_id = $1`,
		`DELETE FROM community_moderators WHERE user_id = $1`,
		// Both directions, so other people's counters drop too.
		`DELETE FROM user_follows WHERE follower_id = $1 OR followee_id = $1`,
	} {
		if _, err := tx.Exec(ctx, sql, id); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx,
		`UPDATE refresh_tokens SET revoked_at = $2 WHERE user_id = $1 AND revoked_at IS NULL`, id, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// optionalText trims an optional field; empty means clear (nil).
func optionalText(field string, v *string, max int) (*string, error) {
	if v == nil {
		return nil, nil
	}
	t := strings.TrimSpace(*v)
	if utf8.RuneCountInString(t) > max {
		return nil, &ValidationError{field, "at most " + strconv.Itoa(max) + " characters"}
	}
	if t == "" {
		return nil, nil
	}
	return &t, nil
}

func isUniqueViolation(err error) bool {
	var pgErr interface{ SQLState() string }
	return errors.As(err, &pgErr) && pgErr.SQLState() == "23505"
}
