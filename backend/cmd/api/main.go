// Command api serves the HTTP and WebSocket API.
package main

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"vetka/internal/auth"
	"vetka/internal/comment"
	"vetka/internal/community"
	"vetka/internal/config"
	"vetka/internal/httpapi"
	"vetka/internal/platform/logging"
	"vetka/internal/platform/postgres"
	"vetka/internal/platform/redis"
	"vetka/internal/post"
	"vetka/internal/user"
	"vetka/internal/vote"
)

func main() {
	if err := run(); err != nil {
		slog.Error("api stopped", slog.Any("err", err))
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

	db, err := postgres.Connect(ctx, cfg.DatabaseURL, cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer db.Close()

	rdb, err := redis.Connect(ctx, cfg.RedisURL, log)
	if err != nil {
		return err
	}
	defer rdb.Close()

	signingKey := cfg.JWTSigningKey
	if signingKey == nil {
		_, signingKey, _ = ed25519.GenerateKey(nil)
		log.Warn("JWT_SIGNING_KEY not set, using an ephemeral key: all sessions end on restart")
	}
	authSvc := auth.NewService(db,
		auth.NewIssuer(signingKey, cfg.AccessTokenTTL),
		auth.NewAppleVerifier(cfg.AppleBundleID),
		redis.ReplayGuard{Client: rdb},
		auth.Config{
			RefreshTTL:       cfg.RefreshTokenTTL,
			RefreshGrace:     cfg.RefreshGrace,
			TelegramBotToken: cfg.TelegramBotToken,
			TelegramMaxAge:   time.Hour,
		},
		log,
	)

	srv := &http.Server{
		Addr: cfg.HTTPAddr,
		Handler: httpapi.NewRouter(httpapi.Deps{
			Logger:         log,
			RequestTimeout: cfg.RequestTimeout,
			Checks: map[string]httpapi.Check{
				"postgres": db.Ping,
				"redis":    func(ctx context.Context) error { return rdb.Ping(ctx).Err() },
			},
			Auth:          authSvc,
			Users:         user.NewStore(db),
			Communities:   community.NewService(db),
			Posts:         post.NewService(db, redis.Limiter{Client: rdb}),
			Votes:         vote.NewService(db, redis.Limiter{Client: rdb}),
			Comments:      comment.NewService(db, redis.Limiter{Client: rdb}),
			TelegramBot:   cfg.TelegramBotUsername,
			PublicBaseURL: cfg.PublicBaseURL,
			AppScheme:     cfg.AppScheme,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		// Request bodies are small: media goes straight to S3 via presigned URLs.
		ReadTimeout: 15 * time.Second,
		// No WriteTimeout: it would cut WebSocket connections. Plain routes are
		// bounded by the request timeout middleware instead.
		IdleTimeout: 120 * time.Second,
		ErrorLog:    slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}

	serveErr := make(chan error, 1)
	go func() {
		log.Info("listening", slog.String("addr", cfg.HTTPAddr))
		serveErr <- srv.ListenAndServe()
	}()

	select {
	case err := <-serveErr:
		return fmt.Errorf("http server: %w", err)
	case <-ctx.Done():
	}

	// Restore default signal handling: a second Ctrl+C kills the process at once.
	stop()
	log.Info("shutting down", slog.Duration("timeout", cfg.ShutdownTimeout))

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	// Stops accepting, waits for in-flight requests, then the deferred
	// db/redis Close calls run once nothing uses them anymore.
	if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("shutdown: %w", err)
	}
	log.Info("stopped")
	return nil
}
