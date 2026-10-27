// Package ranking implements feed orderings.
package ranking

import (
	"math"
	"time"
)

// epochMicros is the zero point of the time component (2026-01-01T00:00:00Z).
// Tau is the age, in seconds, worth one order of magnitude of score: a post
// 12.5h younger needs 10x fewer net votes to rank the same.
//
// Both constants are mirrored in the hot_rank() SQL function. Changing either
// one requires a backfill:
//
//	UPDATE posts SET hot_rank = hot_rank(upvotes, downvotes, created_at);
const (
	epochMicros = 1767225600 * 1_000_000
	Tau         = 45000.0
)

// Hot ranks a post for the "hot" feed.
//
// The score part is logarithmic, so the first votes matter most and a viral
// post cannot dominate forever. The time part grows linearly with the
// creation time instead of decaying with age, so the rank of a post changes
// only when its votes change: no periodic recompute, and the (hot_rank, id)
// index stays valid between votes.
func Hot(ups, downs int, createdAt time.Time) float64 {
	score := float64(ups - downs)
	order := math.Log10(1 + math.Abs(score))

	var sign float64
	switch {
	case score > 0:
		sign = 1
	case score < 0:
		sign = -1
	}

	seconds := float64(createdAt.UnixMicro()-epochMicros) / 1e6
	return sign*order + seconds/Tau
}
