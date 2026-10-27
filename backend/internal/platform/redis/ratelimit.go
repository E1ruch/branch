package redis

import (
	"context"
	"time"

	goredis "github.com/redis/go-redis/v9"
)

// Limiter is a fixed-window rate limiter shared by all api instances.
//
// Fixed windows let a burst of 2x the limit through at a window edge; for
// anti-spam limits like "10 posts an hour" that is fine and costs one round trip.
type Limiter struct {
	Client *goredis.Client
}

// Allow counts one event for key and reports whether it fits in limit per window.
func (l Limiter) Allow(ctx context.Context, key string, limit int, window time.Duration) (bool, error) {
	k := "ratelimit:" + key
	var incr *goredis.IntCmd
	_, err := l.Client.TxPipelined(ctx, func(p goredis.Pipeliner) error {
		incr = p.Incr(ctx, k)
		// NX: the window starts at the first event and is not extended by later ones.
		p.ExpireNX(ctx, k, window)
		return nil
	})
	if err != nil {
		return false, err
	}
	return incr.Val() <= int64(limit), nil
}
