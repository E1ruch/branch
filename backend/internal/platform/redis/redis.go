// Package redis opens the shared Redis client (feed cache, counters, pub/sub).
package redis

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	goredis "github.com/redis/go-redis/v9"
)

// slogAdapter routes go-redis internal messages (dial retries and the like)
// into the service log instead of its own stderr format.
type slogAdapter struct{ log *slog.Logger }

func (a slogAdapter) Printf(ctx context.Context, format string, v ...any) {
	a.log.WarnContext(ctx, fmt.Sprintf(format, v...), slog.String("component", "redis"))
}

func Connect(ctx context.Context, url string, log *slog.Logger) (*goredis.Client, error) {
	goredis.SetLogger(slogAdapter{log})

	opts, err := goredis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("redis: parse url: %w", err)
	}
	client := goredis.NewClient(opts)

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := client.Ping(pingCtx).Err(); err != nil {
		client.Close()
		return nil, fmt.Errorf("redis: ping: %w", err)
	}
	return client, nil
}
