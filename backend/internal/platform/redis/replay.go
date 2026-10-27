package redis

import (
	"context"
	"time"

	goredis "github.com/redis/go-redis/v9"
)

// ReplayGuard implements auth.ReplayGuard with SET NX: the first caller of a
// key wins, every later one within ttl is a replay.
type ReplayGuard struct {
	Client *goredis.Client
}

func (g ReplayGuard) Claim(ctx context.Context, key string, ttl time.Duration) (bool, error) {
	return g.Client.SetNX(ctx, "replay:"+key, 1, ttl).Result()
}
