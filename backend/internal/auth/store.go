package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/user"
)

type store struct {
	db *pgxpool.Pool
}

// findOrCreateUser returns the user bound to (provider, subject), creating the
// user and the identity on first sign-in. created reports which happened.
func (s *store) findOrCreateUser(ctx context.Context, provider, subject string, usernames []string, displayName *string) (u user.User, created bool, err error) {
	u, err = s.userByIdentity(ctx, provider, subject)
	if !errors.Is(err, user.ErrNotFound) {
		return u, false, err
	}

	u, err = s.createUser(ctx, provider, subject, usernames, displayName)
	if errors.Is(err, errIdentityTaken) {
		// A concurrent first sign-in of the same account won the race.
		u, err = s.userByIdentity(ctx, provider, subject)
		return u, false, err
	}
	return u, err == nil, err
}

func (s *store) userByIdentity(ctx context.Context, provider, subject string) (user.User, error) {
	return user.Scan(s.db.QueryRow(ctx, `
		SELECT `+user.Columns+` FROM users
		WHERE id = (SELECT user_id FROM auth_identities WHERE provider = $1 AND subject = $2)`,
		provider, subject))
}

var errIdentityTaken = errors.New("identity already bound")

func (s *store) createUser(ctx context.Context, provider, subject string, usernames []string, displayName *string) (user.User, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return user.User{}, err
	}
	defer tx.Rollback(ctx)

	u, err := insertUser(ctx, tx, usernames, displayName)
	if err != nil {
		return user.User{}, err
	}

	tag, err := tx.Exec(ctx, `
		INSERT INTO auth_identities (provider, subject, user_id) VALUES ($1, $2, $3)
		ON CONFLICT DO NOTHING`, provider, subject, u.ID)
	if err != nil {
		return user.User{}, err
	}
	if tag.RowsAffected() == 0 {
		return user.User{}, errIdentityTaken
	}
	return u, tx.Commit(ctx)
}

// insertUser takes the first free username. ON CONFLICT keeps the transaction
// usable after a collision, unlike catching a unique violation.
func insertUser(ctx context.Context, tx pgx.Tx, usernames []string, displayName *string) (user.User, error) {
	for _, name := range usernames {
		u, err := user.Scan(tx.QueryRow(ctx, `
			INSERT INTO users (username, display_name) VALUES ($1, $2)
			ON CONFLICT (username) DO NOTHING
			RETURNING `+user.Columns, name, displayName))
		if errors.Is(err, user.ErrNotFound) {
			continue
		}
		return u, err
	}
	return user.User{}, fmt.Errorf("auth: all %d username candidates taken", len(usernames))
}

func (s *store) createRefreshToken(ctx context.Context, userID int64, hash []byte, device string, now, expiresAt time.Time) error {
	_, err := s.db.Exec(ctx, `
		INSERT INTO refresh_tokens (user_id, token_hash, family_id, device_name, created_at, expires_at)
		VALUES ($1, $2, gen_random_uuid(), NULLIF($3, ''), $4, $5)`,
		userID, hash, device, now, expiresAt)
	return err
}

// rotateRefreshToken exchanges oldHash for newHash in the same family.
//
//   - revoked or expired: ErrRefreshInvalid;
//   - already rotated within grace: a client retry after a lost response,
//     so another token is issued and the family survives;
//   - already rotated earlier: the token leaked and someone replays it, so
//     the whole family is revoked (ErrRefreshReused) and both the thief and
//     the owner have to sign in again.
func (s *store) rotateRefreshToken(ctx context.Context, oldHash, newHash []byte, now time.Time, ttl, grace time.Duration) (int64, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	var (
		id, userID           int64
		family               pgtype.UUID
		expiresAt            time.Time
		rotatedAt, revokedAt *time.Time
	)
	err = tx.QueryRow(ctx, `
		SELECT id, user_id, family_id, expires_at, rotated_at, revoked_at
		FROM refresh_tokens WHERE token_hash = $1 FOR UPDATE`, oldHash).
		Scan(&id, &userID, &family, &expiresAt, &rotatedAt, &revokedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrRefreshInvalid
	}
	if err != nil {
		return 0, err
	}

	switch {
	case revokedAt != nil || !now.Before(expiresAt):
		return 0, ErrRefreshInvalid
	case rotatedAt != nil && now.Sub(*rotatedAt) > grace:
		if _, err := tx.Exec(ctx, `
			UPDATE refresh_tokens SET revoked_at = $2
			WHERE family_id = $1 AND revoked_at IS NULL`, family, now); err != nil {
			return 0, err
		}
		if err := tx.Commit(ctx); err != nil {
			return 0, err
		}
		return 0, ErrRefreshReused
	case rotatedAt == nil:
		if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET rotated_at = $2 WHERE id = $1`, id, now); err != nil {
			return 0, err
		}
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO refresh_tokens (user_id, token_hash, family_id, device_name, created_at, expires_at)
		SELECT user_id, $2, family_id, device_name, $3, $4 FROM refresh_tokens WHERE id = $1`,
		id, newHash, now, now.Add(ttl)); err != nil {
		return 0, err
	}
	return userID, tx.Commit(ctx)
}

// revokeFamily logs out the device that owns the token. Unknown tokens are
// ignored, so logout is idempotent.
func (s *store) revokeFamily(ctx context.Context, hash []byte, now time.Time) error {
	_, err := s.db.Exec(ctx, `
		UPDATE refresh_tokens SET revoked_at = $2
		WHERE family_id = (SELECT family_id FROM refresh_tokens WHERE token_hash = $1)
		  AND revoked_at IS NULL`, hash, now)
	return err
}
