// Package search keeps what people search for, for the "Популярные
// запросы" chips. The searching itself lives next to each thing searched
// (community, user, post).
package search

import (
	"context"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	MinQueryLen = 2
	maxQueryLen = 64
	// A query must come from this many different people within the window
	// to trend: one person (or a typo) cannot put a word on everyone's
	// search screen.
	minPeople = 3
	window    = 7 * 24 * time.Hour
)

type Service struct {
	db  *pgxpool.Pool
	now func() time.Time
}

func NewService(db *pgxpool.Pool) *Service {
	return &Service{db: db, now: time.Now}
}

// Normalize makes "  Юмор  И  мемы" and "юмор и мемы" one query. The
// second result is false for queries too short or too long to keep.
func Normalize(query string) (string, bool) {
	q := strings.Join(strings.Fields(strings.ToLower(query)), " ")
	n := utf8.RuneCountInString(q)
	return q, n >= MinQueryLen && n <= maxQueryLen
}

// Record counts a search the user meant (submitted, or followed to a
// result), not every prefix typed on the way. Repeats the same day are free.
func (s *Service) Record(ctx context.Context, userID int64, query string) error {
	q, ok := Normalize(query)
	if !ok {
		return nil
	}
	_, err := s.db.Exec(ctx, `
		INSERT INTO search_query_hits (day, query, user_id) VALUES ($1, $2, $3)
		ON CONFLICT DO NOTHING`, s.now().UTC().Truncate(24*time.Hour), q, userID)
	return err
}

// Popular is what most people searched for this week. While there is not
// enough of that (a young site), the biggest communities' names fill the
// rest: they are what people come for anyway.
func (s *Service) Popular(ctx context.Context, limit int) ([]string, error) {
	since := s.now().UTC().Add(-window).Truncate(24 * time.Hour)
	rows, err := s.db.Query(ctx, `
		(SELECT query, count(*) AS people, 0 AS kind
		 FROM search_query_hits WHERE day >= $1
		 GROUP BY query HAVING count(DISTINCT user_id) >= $2
		 ORDER BY people DESC, query
		 LIMIT $3)
		UNION ALL
		(SELECT lower(title), subscribers_count, 1
		 FROM communities WHERE NOT is_nsfw
		 ORDER BY subscribers_count DESC, id DESC
		 LIMIT $3)
		ORDER BY kind, people DESC`, since, minPeople, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	seen := map[string]bool{}
	for rows.Next() {
		var (
			q          string
			people, kd int
		)
		if err := rows.Scan(&q, &people, &kd); err != nil {
			return nil, err
		}
		if !seen[q] && len(out) < limit {
			seen[q] = true
			out = append(out, q)
		}
	}
	return out, rows.Err()
}

// Prune drops what Popular no longer looks at (the same window start);
// the worker runs it hourly.
func Prune(ctx context.Context, db *pgxpool.Pool, now time.Time) (int64, error) {
	tag, err := db.Exec(ctx, `DELETE FROM search_query_hits WHERE day < $1`,
		now.UTC().Add(-window).Truncate(24*time.Hour))
	return tag.RowsAffected(), err
}
