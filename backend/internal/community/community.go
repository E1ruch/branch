// Package community owns communities, subscriptions and moderator roles.
package community

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrNotFound    = errors.New("community: not found")
	ErrSlugTaken   = errors.New("community: slug taken")
	ErrForbidden   = errors.New("community: forbidden")
	ErrRateLimited = errors.New("community: too many communities created")
)

// ValidationError names the input field that broke a rule.
type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string { return e.Field + ": " + e.Message }

type Community struct {
	ID               int64
	Slug             string
	Title            string
	Description      string
	IsNSFW           bool
	SubscribersCount int
	CreatedAt        time.Time

	// Relative to the viewer; false/nil for anonymous requests.
	IsSubscribed bool
	ViewerRole   *string // "owner" or "moderator"
}

const (
	// Creation is cheap to abuse: an empty community squats a good slug forever.
	maxCreatedPerDay = 3
	maxTitle         = 64
	maxDescription   = 1000
)

// Same rule as the communities.slug CHECK constraint.
var slugRe = regexp.MustCompile(`^[A-Za-z0-9_]{3,32}$`)

// Slugs that collide with app routes or could pass for official spaces.
var reservedSlugs = map[string]bool{
	"all": true, "popular": true, "new": true, "hot": true, "top": true,
	"search": true, "feed": true, "me": true, "admin": true, "moderator": true,
	"settings": true, "help": true, "support": true, "official": true,
	"vetka": true, "api": true, "null": true, "undefined": true,
}

type Service struct {
	db  *pgxpool.Pool
	now func() time.Time
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{db: db, now: time.Now}
}

// Every read joins the viewer's subscription and role in the same query, so a
// list of 25 communities costs one round trip. Viewer 0 is anonymous and
// matches no rows (user IDs start at 1).
const selectWithViewer = `
	SELECT c.id, c.slug, c.title, c.description, c.is_nsfw, c.subscribers_count, c.created_at,
	       m.user_id IS NOT NULL, mod.role::text
	FROM communities c
	LEFT JOIN community_members m      ON m.community_id = c.id AND m.user_id = $1
	LEFT JOIN community_moderators mod ON mod.community_id = c.id AND mod.user_id = $1`

func scan(row pgx.Row) (Community, error) {
	var c Community
	err := row.Scan(&c.ID, &c.Slug, &c.Title, &c.Description, &c.IsNSFW, &c.SubscribersCount, &c.CreatedAt,
		&c.IsSubscribed, &c.ViewerRole)
	if errors.Is(err, pgx.ErrNoRows) {
		return Community{}, ErrNotFound
	}
	return c, err
}

func collect(rows pgx.Rows, err error) ([]Community, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Community{}
	for rows.Next() {
		c, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Service) Get(ctx context.Context, slug string, viewer int64) (Community, error) {
	return scan(s.db.QueryRow(ctx, selectWithViewer+` WHERE c.slug = $2`, viewer, slug))
}

type CreateInput struct {
	Slug        string
	Title       string
	Description string
	IsNSFW      bool
}

// Create makes the community with the creator as its owner and first subscriber.
func (s *Service) Create(ctx context.Context, userID int64, in CreateInput) (Community, error) {
	in.Title = strings.TrimSpace(in.Title)
	in.Description = strings.TrimSpace(in.Description)
	if err := validateSlug(in.Slug); err != nil {
		return Community{}, err
	}
	if err := validateText("title", in.Title, 1, maxTitle); err != nil {
		return Community{}, err
	}
	if err := validateText("description", in.Description, 0, maxDescription); err != nil {
		return Community{}, err
	}

	now := s.now()
	var created int
	if err := s.db.QueryRow(ctx,
		`SELECT count(*) FROM communities WHERE created_by = $1 AND created_at > $2`,
		userID, now.Add(-24*time.Hour)).Scan(&created); err != nil {
		return Community{}, err
	}
	if created >= maxCreatedPerDay {
		return Community{}, ErrRateLimited
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Community{}, err
	}
	defer tx.Rollback(ctx)

	var id int64
	err = tx.QueryRow(ctx, `
		INSERT INTO communities (slug, title, description, is_nsfw, created_by, created_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (slug) DO NOTHING
		RETURNING id`, in.Slug, in.Title, in.Description, in.IsNSFW, userID, now).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return Community{}, ErrSlugTaken
	}
	if err != nil {
		return Community{}, err
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO community_moderators (community_id, user_id, role) VALUES ($1, $2, 'owner')`, id, userID); err != nil {
		return Community{}, err
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO community_members (user_id, community_id) VALUES ($1, $2)`, userID, id); err != nil {
		return Community{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Community{}, err
	}
	return s.Get(ctx, in.Slug, userID)
}

// UpdateInput changes only the non-nil fields.
type UpdateInput struct {
	Title       *string
	Description *string
	IsNSFW      *bool
}

func (s *Service) Update(ctx context.Context, slug string, userID int64, in UpdateInput) (Community, error) {
	if in.Title != nil {
		t := strings.TrimSpace(*in.Title)
		if err := validateText("title", t, 1, maxTitle); err != nil {
			return Community{}, err
		}
		in.Title = &t
	}
	if in.Description != nil {
		d := strings.TrimSpace(*in.Description)
		if err := validateText("description", d, 0, maxDescription); err != nil {
			return Community{}, err
		}
		in.Description = &d
	}

	tag, err := s.db.Exec(ctx, `
		UPDATE communities c SET
			title       = COALESCE($3, c.title),
			description = COALESCE($4, c.description),
			is_nsfw     = COALESCE($5, c.is_nsfw)
		WHERE c.slug = $1
		  AND EXISTS (SELECT 1 FROM community_moderators WHERE community_id = c.id AND user_id = $2)`,
		slug, userID, in.Title, in.Description, in.IsNSFW)
	if err != nil {
		return Community{}, err
	}
	c, err := s.Get(ctx, slug, userID)
	if err != nil {
		return Community{}, err
	}
	if tag.RowsAffected() == 0 {
		return Community{}, ErrForbidden // it exists, so the moderator check failed
	}
	return c, nil
}

// Subscribe and Unsubscribe set the desired state rather than toggle it, so
// retries and double taps are harmless. Both return the fresh community for
// the client to reconcile its optimistic counter.
func (s *Service) Subscribe(ctx context.Context, slug string, userID int64) (Community, error) {
	// Zero rows inserted means already subscribed or no such community; Get tells which.
	if _, err := s.db.Exec(ctx, `
		INSERT INTO community_members (user_id, community_id)
		SELECT $1, id FROM communities WHERE slug = $2
		ON CONFLICT DO NOTHING`, userID, slug); err != nil {
		return Community{}, err
	}
	return s.Get(ctx, slug, userID)
}

func (s *Service) Unsubscribe(ctx context.Context, slug string, userID int64) (Community, error) {
	if _, err := s.db.Exec(ctx, `
		DELETE FROM community_members
		WHERE user_id = $1 AND community_id = (SELECT id FROM communities WHERE slug = $2)`,
		userID, slug); err != nil {
		return Community{}, err
	}
	return s.Get(ctx, slug, userID)
}

// PopularCursor is the last item of the previous page.
type PopularCursor struct {
	Subscribers int   `json:"s"`
	ID          int64 `json:"i"`
}

// Popular lists communities by subscribers. NSFW ones are left out of
// discovery: App Store rules require such content to be hidden by default.
func (s *Service) Popular(ctx context.Context, viewer int64, after *PopularCursor, limit int) ([]Community, error) {
	// No cursor = start above any real row, so one query (and one plan) serves every page.
	cur := PopularCursor{Subscribers: math.MaxInt32, ID: math.MaxInt64}
	if after != nil {
		cur = *after
	}
	return collect(s.db.Query(ctx, selectWithViewer+`
		WHERE NOT c.is_nsfw AND (c.subscribers_count, c.id) < ($2, $3)
		ORDER BY c.subscribers_count DESC, c.id DESC
		LIMIT $4`, viewer, cur.Subscribers, cur.ID, limit))
}

const MinSearchLen = 2

// Search matches the query anywhere in the slug or title (trigram index).
// An exact slug match goes first, then closer matches, then bigger communities.
func (s *Service) Search(ctx context.Context, query string, viewer int64, limit int) ([]Community, error) {
	query = strings.TrimSpace(query)
	if utf8.RuneCountInString(query) < MinSearchLen {
		return []Community{}, nil
	}
	return collect(s.db.Query(ctx, selectWithViewer+`
		WHERE NOT c.is_nsfw AND (c.slug::text || ' ' || c.title) ILIKE $2
		ORDER BY c.slug = $3::citext DESC,
		         similarity(c.slug::text || ' ' || c.title, $3) DESC,
		         c.subscribers_count DESC, c.id DESC
		LIMIT $4`, viewer, "%"+escapeLike(query)+"%", query, limit))
}

// maxSubscriptions caps the list; the app keeps it whole for the sidebar and
// the subscriptions feed, so it is not paginated.
const maxSubscriptions = 1000

func (s *Service) Subscriptions(ctx context.Context, userID int64) ([]Community, error) {
	return collect(s.db.Query(ctx, selectWithViewer+`
		WHERE m.user_id IS NOT NULL
		ORDER BY c.title, c.id
		LIMIT $2`, userID, maxSubscriptions))
}

func validateSlug(slug string) error {
	if !slugRe.MatchString(slug) {
		return &ValidationError{"slug", "3-32 latin letters, digits or underscores"}
	}
	if reservedSlugs[strings.ToLower(slug)] {
		return &ValidationError{"slug", "this name is reserved"}
	}
	return nil
}

func validateText(field, s string, min, max int) error {
	n := utf8.RuneCountInString(s)
	if n < min || n > max {
		return &ValidationError{field, fmt.Sprintf("length must be %d-%d characters", min, max)}
	}
	return nil
}

var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

func escapeLike(s string) string { return likeEscaper.Replace(s) }
