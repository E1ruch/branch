package media

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

const (
	// A staging object remains writable until the upload signature expires.
	// Wait an hour (longer than the signature lifetime) before deleting it.
	stagingExpired = `m.upload_key IS NOT NULL AND m.status = 'ready'
		AND m.created_at < now() - interval '1 hour'`
	unattached = `(m.post_id IS NULL OR NOT EXISTS (
		SELECT 1 FROM posts p WHERE p.id = m.post_id AND p.deleted_at IS NULL
	))
		AND NOT EXISTS (SELECT 1 FROM users u WHERE u.avatar_key = m.storage_key)
		AND NOT EXISTS (SELECT 1 FROM communities c WHERE c.icon_key = m.storage_key)
		AND NOT EXISTS (SELECT 1 FROM communities c WHERE c.banner_key = m.storage_key)`
	orphanExpired = `(m.upload_key IS NOT NULL OR m.content_digest IS NOT NULL)
		AND m.created_at < now() - interval '24 hours'
		AND (m.publish_started_at IS NULL OR m.publish_started_at < now() - interval '5 minutes')
		AND ` + unattached
)

// Sweep removes a batch of stale staging objects and expired unlinked media.
func (s *Service) Sweep(ctx context.Context) error {
	rows, err := s.db.Query(ctx, `
		SELECT m.id FROM media m WHERE (`+stagingExpired+`) OR (`+orphanExpired+`)
		ORDER BY m.created_at, m.id LIMIT 100`)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	var sweepErr error
	for _, id := range ids {
		if ctx.Err() != nil {
			return errors.Join(sweepErr, ctx.Err())
		}
		if err := s.collectExpired(ctx, id); err != nil {
			sweepErr = errors.Join(sweepErr, fmt.Errorf("media %d: %w", id, err))
		}
	}
	return sweepErr
}

func (s *Service) collectExpired(ctx context.Context, id int64) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var key string
	var stagingKey *string
	err = tx.QueryRow(ctx, `SELECT storage_key, upload_key FROM media WHERE id = $1 FOR UPDATE SKIP LOCKED`, id).
		Scan(&key, &stagingKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}

	// Read after taking the row lock. The listing's snapshot may have missed
	// an attachment that committed while this worker was acquiring the lock.
	var removeStaging, removeAll bool
	if err := tx.QueryRow(ctx, `
		SELECT (`+stagingExpired+`), (`+orphanExpired+`) FROM media m WHERE m.id = $1`, id).
		Scan(&removeStaging, &removeAll); err != nil {
		return err
	}
	if removeAll {
		// Commit the tombstone before external deletion. If object deletion
		// succeeds and SQL cleanup fails, the row must not be attachable.
		if _, err := tx.Exec(ctx, `UPDATE media SET status = 'failed' WHERE id = $1`, id); err != nil {
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		if stagingKey != nil {
			if err := s.storage.Delete(ctx, *stagingKey); err != nil {
				return err
			}
		}
		if err := s.storage.Delete(ctx, key); err != nil {
			return err
		}
		_, err := s.db.Exec(ctx, `DELETE FROM media WHERE id = $1 AND status = 'failed'`, id)
		return err
	}
	if removeStaging {
		if err := s.storage.Delete(ctx, *stagingKey); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE media SET upload_key = NULL WHERE id = $1`, id); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
