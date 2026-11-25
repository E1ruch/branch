// Package media validates uploads, tracks their lifetime, and associates
// completed images with app records.
package media

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"time"

	thumbhash "github.com/galdor/go-thumbhash"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	MaxBytes       = 10 << 20
	maxSide        = 8192
	maxPixels      = 24_000_000
	uploadLimit    = 60
	postImageLimit = 4
)

var (
	ErrNotFound      = errors.New("media: not found")
	ErrUploadMissing = errors.New("media: upload missing")
	ErrRateLimited   = errors.New("media: upload limit reached")
	ErrInvalidImage  = errors.New("media: the upload is not a matching, supported image")
	ErrInvalidID     = errors.New("media: image not available")
)

// Image carries only database metadata. The API adds size-specific URLs.
type Image struct {
	ID        int64  `json:"id"`
	Key       string `json:"key"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
	ThumbHash []byte `json:"thumbhash"`
}

type Upload struct {
	ID      int64             `json:"id"`
	URL     string            `json:"upload_url"`
	Headers map[string]string `json:"headers"`
}

type InputError struct {
	Field   string
	Message string
}

func (e *InputError) Error() string { return e.Field + ": " + e.Message }

type ObjectStorage interface {
	PresignUpload(ctx context.Context, key, mime string, size int64) (string, map[string]string, error)
	OpenUpload(ctx context.Context, key string) (io.ReadCloser, error)
	Publish(ctx context.Context, key, mime string, data []byte) error
	Delete(ctx context.Context, key string) error
	ImageURL(key string, width int) string
}

type Limiter interface {
	Allow(ctx context.Context, key string, limit int, window time.Duration) (bool, error)
}

type Service struct {
	db       *pgxpool.Pool
	storage  ObjectStorage
	limiter  Limiter
	decoders chan struct{}
}

func NewService(db *pgxpool.Pool, storage ObjectStorage, limiter Limiter) *Service {
	return &Service{db: db, storage: storage, limiter: limiter, decoders: make(chan struct{}, 2)}
}

// ImageURL also supports an optional service so old text-only deployments
// can keep using the same handlers.
func (s *Service) ImageURL(key string, width int) string {
	if s == nil || key == "" {
		return ""
	}
	return s.storage.ImageURL(key, width)
}

func (s *Service) BeginUpload(ctx context.Context, owner int64, mime string, size int64) (Upload, error) {
	extension, ok := map[string]string{"image/jpeg": ".jpg", "image/png": ".png"}[mime]
	if !ok {
		return Upload{}, &InputError{Field: "mime_type", Message: "use image/jpeg or image/png"}
	}
	if size <= 0 || size > MaxBytes {
		return Upload{}, &InputError{Field: "size_bytes", Message: "image must be between 1 byte and 10 MiB"}
	}
	if s.limiter != nil {
		ok, err := s.limiter.Allow(ctx, fmt.Sprintf("media:upload:%d", owner), uploadLimit, time.Hour)
		if err != nil {
			return Upload{}, err
		}
		if !ok {
			return Upload{}, ErrRateLimited
		}
	}

	token := rand.Text()
	stagingKey, finalKey := "uploads/"+token, "images/"+token+extension
	url, headers, err := s.storage.PresignUpload(ctx, stagingKey, mime, size)
	if err != nil {
		return Upload{}, err
	}
	out := Upload{URL: url, Headers: headers}
	if out.Headers == nil {
		out.Headers = map[string]string{}
	}
	err = s.db.QueryRow(ctx, `
		INSERT INTO media (owner_id, upload_key, storage_key, kind, mime_type, size_bytes)
		SELECT id, $2, $3, 'image', $4, $5 FROM users WHERE id = $1 AND deleted_at IS NULL
		RETURNING id`, owner, stagingKey, finalKey, mime, size).Scan(&out.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Upload{}, ErrNotFound
	}
	return out, err
}

type uploadRecord struct {
	image      Image
	ready      bool
	stagingKey *string
	mime       string
	size       *int64
	digest     []byte
}

const readUpload = `
	SELECT m.id, m.storage_key, COALESCE(m.width, 0), COALESCE(m.height, 0), m.thumbhash,
	       m.status = 'ready', m.upload_key, m.mime_type, m.size_bytes, m.content_digest
	FROM media m
	WHERE m.id = $1 AND m.owner_id = $2 AND m.kind = 'image'
	  AND ((m.status = 'ready' AND m.content_digest IS NOT NULL)
	      OR (m.status = 'pending' AND m.upload_key IS NOT NULL AND m.created_at > now() - interval '24 hours'))
	  AND EXISTS (SELECT 1 FROM users WHERE id = m.owner_id AND deleted_at IS NULL)`

func scanUpload(row pgx.Row) (uploadRecord, error) {
	var u uploadRecord
	err := row.Scan(&u.image.ID, &u.image.Key, &u.image.Width, &u.image.Height, &u.image.ThumbHash,
		&u.ready, &u.stagingKey, &u.mime, &u.size, &u.digest)
	if errors.Is(err, pgx.ErrNoRows) {
		return uploadRecord{}, ErrNotFound
	}
	return u, err
}

func (s *Service) Complete(ctx context.Context, owner, id int64) (Image, error) {
	u, err := scanUpload(s.db.QueryRow(ctx, readUpload, id, owner))
	if err != nil || u.ready {
		return u.image, err
	}

	// Bound the memory used by simultaneous full decodes.
	select {
	case s.decoders <- struct{}{}:
		defer func() { <-s.decoders }()
	case <-ctx.Done():
		return Image{}, ctx.Err()
	}
	if u.stagingKey == nil || u.size == nil {
		return Image{}, ErrInvalidImage
	}
	data, width, height, hash, err := s.validateUpload(ctx, *u.stagingKey, u.mime, *u.size)
	if err != nil {
		// Another completion might have succeeded while this request was
		// waiting for a decoder and its staging object may already be gone.
		current, loadErr := scanUpload(s.db.QueryRow(ctx, readUpload, id, owner))
		if loadErr == nil && current.ready {
			return current.image, nil
		}
		return Image{}, err
	}
	digest := sha256.Sum256(data)

	// Persist the checksum before the external write. Even after an ambiguous
	// publish result, retries can write only these exact bytes to the final key.
	if _, err := s.db.Exec(ctx, `
		UPDATE media SET content_digest = $3, publish_started_at = now()
		WHERE id = $1 AND owner_id = $2 AND status = 'pending'
		  AND (content_digest IS NULL OR content_digest = $3)
		  AND created_at > now() - interval '24 hours'`, id, owner, digest[:]); err != nil {
		return Image{}, err
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Image{}, err
	}
	defer tx.Rollback(ctx)
	u, err = scanUpload(tx.QueryRow(ctx, readUpload+" FOR UPDATE OF m", id, owner))
	if err != nil || u.ready {
		return u.image, err
	}
	if !bytes.Equal(u.digest, digest[:]) {
		return Image{}, ErrInvalidImage
	}
	if err := s.storage.Publish(ctx, u.image.Key, u.mime, data); err != nil {
		return Image{}, err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE media SET status = 'ready', width = $2, height = $3, thumbhash = $4
		WHERE id = $1`, id, width, height, hash); err != nil {
		return Image{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Image{}, err
	}
	u.image.Width, u.image.Height, u.image.ThumbHash = width, height, hash
	return u.image, nil
}

func (s *Service) validateUpload(ctx context.Context, key, mime string, expectedSize int64) ([]byte, int, int, []byte, error) {
	if expectedSize <= 0 || expectedSize > MaxBytes {
		return nil, 0, 0, nil, ErrInvalidImage
	}
	body, err := s.storage.OpenUpload(ctx, key)
	if err != nil {
		return nil, 0, 0, nil, err
	}
	defer body.Close()
	data, err := io.ReadAll(io.LimitReader(body, expectedSize+1))
	if err != nil {
		return nil, 0, 0, nil, err
	}
	if int64(len(data)) != expectedSize {
		return nil, 0, 0, nil, ErrInvalidImage
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || "image/"+format != mime || config.Width <= 0 || config.Height <= 0 ||
		config.Width > maxSide || config.Height > maxSide || config.Width*config.Height > maxPixels {
		return nil, 0, 0, nil, ErrInvalidImage
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil || img.Bounds().Dx() != config.Width || img.Bounds().Dy() != config.Height {
		return nil, 0, 0, nil, ErrInvalidImage
	}
	return data, config.Width, config.Height, encodeThumbHash(img), nil
}

// ThumbHash uses at most 100 pixels on either side. Sampling the source
// keeps memory and DCT work independent of the uploaded image's dimensions.
func encodeThumbHash(img image.Image) []byte {
	const maxHashSide = 100
	bounds := img.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	scale := max(width, height)
	if scale <= maxHashSide {
		return thumbhash.EncodeImage(img)
	}
	w, h := max(1, (width*maxHashSide+scale/2)/scale), max(1, (height*maxHashSide+scale/2)/scale)
	small := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		sourceY := bounds.Min.Y + (2*y+1)*height/(2*h)
		for x := range w {
			sourceX := bounds.Min.X + (2*x+1)*width/(2*w)
			small.Set(x, y, img.At(sourceX, sourceY))
		}
	}
	return thumbhash.EncodeImage(small)
}
