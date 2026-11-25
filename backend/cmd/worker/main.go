// Command worker runs background jobs: folding vote deltas into counters,
// hot rank and karma once a second, counting popular searches every ten
// minutes, and hourly cleanup.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"vetka/internal/config"
	"vetka/internal/media"
	"vetka/internal/platform/logging"
	"vetka/internal/platform/postgres"
	"vetka/internal/search"
	"vetka/internal/vote"
)

const (
	flushInterval = time.Second
	// Big enough to drain a burst quickly, small enough to keep each
	// transaction (and the row locks it holds on posts) short.
	flushBatch    = 5000
	pruneInterval = time.Hour
	// Popular queries lag at most this much behind what people search.
	popularInterval = 10 * time.Minute
)

func main() {
	if err := run(); err != nil {
		slog.Error("worker stopped", slog.Any("err", err))
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := logging.New(cfg.LogLevel, cfg.LogJSON)
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	db, err := postgres.Connect(ctx, cfg.DatabaseURL, 4)
	if err != nil {
		return err
	}
	defer db.Close()

	if cfg, enabled := cfg.MediaStorage(); enabled {
		storage, err := media.NewStorage(cfg)
		if err != nil {
			return fmt.Errorf("media storage: %w", err)
		}
		gcCtx, stopGC := context.WithCancel(ctx)
		gcDone := make(chan struct{})
		go func() {
			defer close(gcDone)
			collectMedia(gcCtx, media.NewService(db, storage, nil), log)
		}()
		defer func() {
			stopGC()
			<-gcDone
		}()
	}

	log.Info("worker started", slog.Duration("flush_interval", flushInterval))
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()
	var pruned, counted time.Time
	for {
		flushVotes(ctx, db, log)
		if time.Since(counted) >= popularInterval {
			counted = time.Now()
			if err := search.RefreshPopular(ctx, db, counted); err != nil {
				log.Error("count popular searches", slog.Any("err", err))
			}
		}
		if time.Since(pruned) >= pruneInterval {
			pruned = time.Now()
			if n, err := search.Prune(ctx, db, pruned); err != nil {
				log.Error("prune search queries", slog.Any("err", err))
			} else if n > 0 {
				log.Debug("search queries pruned", slog.Int64("count", n))
			}
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			stop()
			// Drain once more so votes cast right before a deploy do not wait
			// for the next worker to come up.
			drainCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			flushVotes(drainCtx, db, log)
			log.Info("worker stopped")
			return nil
		}
	}
}

// flushVotes drains pending deltas batch by batch. Errors are logged and the
// deltas stay in place for the next tick: nothing is lost.
func flushVotes(ctx context.Context, db *pgxpool.Pool, log *slog.Logger) {
	for {
		start := time.Now()
		n, err := vote.Flush(ctx, db, flushBatch)
		if err != nil {
			if ctx.Err() == nil {
				log.Error("vote flush failed", slog.Any("err", err))
			}
			return
		}
		if n > 0 {
			log.Debug("vote deltas applied", slog.Int("count", n), slog.Duration("took", time.Since(start)))
		}
		if n < flushBatch {
			return
		}
	}
}

// Media I/O runs on its own schedule so a slow bucket can't delay votes.
func collectMedia(ctx context.Context, svc *media.Service, log *slog.Logger) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for ctx.Err() == nil {
		sweepCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		err := svc.Sweep(sweepCtx)
		cancel()
		if err != nil && ctx.Err() == nil {
			log.ErrorContext(ctx, "collect media", slog.Any("err", err))
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
