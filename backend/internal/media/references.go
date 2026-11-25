package media

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// PostImagesSQL is a SELECT expression for a post aliased p. The post
// position index supplies its images in display order, without extra queries.
const PostImagesSQL = `COALESCE((
	SELECT jsonb_agg(jsonb_build_object(
		'id', m.id, 'key', m.storage_key, 'width', m.width, 'height', m.height,
		'thumbhash', encode(m.thumbhash, 'base64')) ORDER BY m.position)
	FROM media m
	WHERE m.post_id = p.id AND m.status = 'ready' AND m.kind = 'image' AND m.thumbhash IS NOT NULL
), '[]'::jsonb)`

type Reference struct {
	Key    string
	PostID *int64
}

// LockOwnedReady takes locks in ID order, shared by every operation attaching
// images. A caller must write its references in this same transaction. The
// collector checks for references while holding the equivalent lock.
func LockOwnedReady(ctx context.Context, tx pgx.Tx, owner int64, ids []int64) (map[int64]Reference, error) {
	out := make(map[int64]Reference, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := tx.Query(ctx, `
		SELECT id, storage_key, post_id FROM media
		WHERE owner_id = $1 AND id = ANY($2) AND status = 'ready'
		  AND kind = 'image' AND thumbhash IS NOT NULL
		ORDER BY id FOR UPDATE`, owner, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var ref Reference
		if err := rows.Scan(&id, &ref.Key, &ref.PostID); err != nil {
			return nil, err
		}
		out[id] = ref
	}
	return out, rows.Err()
}

// AttachPost preserves the order of IDs sent by the author. The post and
// every image association either commit together or roll back together.
func AttachPost(ctx context.Context, tx pgx.Tx, owner, postID int64, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	if len(ids) > postImageLimit {
		return ErrInvalidID
	}
	refs, err := LockOwnedReady(ctx, tx, owner, ids)
	if err != nil {
		return err
	}
	if len(refs) != len(ids) {
		return ErrInvalidID // also rejects duplicate IDs
	}
	for _, ref := range refs {
		if ref.PostID != nil {
			return ErrInvalidID
		}
	}
	_, err = tx.Exec(ctx, `
		UPDATE media SET post_id = $1, position = requested.ordinality - 1
		FROM unnest($2::bigint[]) WITH ORDINALITY AS requested(id, ordinality)
		WHERE media.id = requested.id`, postID, ids)
	return err
}

// OptionalIDs drops omitted fields and removals before resolving images.
func OptionalIDs(ids ...*int64) []int64 {
	var selected []int64
	for _, id := range ids {
		if id != nil && *id != 0 {
			selected = append(selected, *id)
		}
	}
	return selected
}

// OptionalKey returns nil for an omitted or cleared image. Callers retain
// their current column when the corresponding input pointer was nil.
func OptionalKey(refs map[int64]Reference, id *int64) (*string, error) {
	if id == nil || *id == 0 {
		return nil, nil
	}
	ref, ok := refs[*id]
	if !ok {
		return nil, ErrInvalidID
	}
	return &ref.Key, nil
}
