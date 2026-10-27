// Package config reads service configuration from environment variables.
// Defaults target the local Docker Compose setup, so `make run` works with no .env.
package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"
)

type Config struct {
	HTTPAddr        string
	ShutdownTimeout time.Duration
	RequestTimeout  time.Duration

	DatabaseURL string
	DBMaxConns  int32

	RedisURL string

	LogLevel slog.Level
	LogJSON  bool

	// Nil means none was configured: the api generates an ephemeral key, and
	// every token dies on restart. Fine locally, never in production.
	JWTSigningKey   ed25519.PrivateKey
	AccessTokenTTL  time.Duration
	RefreshTokenTTL time.Duration
	RefreshGrace    time.Duration

	AppleBundleID       string
	TelegramBotToken    string
	TelegramBotUsername string

	PublicBaseURL string
	AppScheme     string
}

func Load() (Config, error) {
	var (
		c    Config
		errs []error
	)

	c.HTTPAddr = str("HTTP_ADDR", ":8080")
	c.ShutdownTimeout = duration("SHUTDOWN_TIMEOUT", 15*time.Second, &errs)
	c.RequestTimeout = duration("REQUEST_TIMEOUT", 10*time.Second, &errs)

	c.DatabaseURL = str("DATABASE_URL", "postgres://vetka:vetka@localhost:5432/vetka?sslmode=disable")
	c.DBMaxConns = int32(integer("DB_MAX_CONNS", 20, &errs))

	c.RedisURL = str("REDIS_URL", "redis://localhost:6379/0")

	if err := c.LogLevel.UnmarshalText([]byte(str("LOG_LEVEL", "info"))); err != nil {
		errs = append(errs, fmt.Errorf("LOG_LEVEL: %w", err))
	}
	c.LogJSON = str("LOG_FORMAT", "text") == "json"

	if v := str("JWT_SIGNING_KEY", ""); v != "" {
		seed, err := base64.StdEncoding.DecodeString(v)
		if err != nil || len(seed) != ed25519.SeedSize {
			errs = append(errs, errors.New("JWT_SIGNING_KEY: want 32 random bytes in base64 (openssl rand -base64 32)"))
		} else {
			c.JWTSigningKey = ed25519.NewKeyFromSeed(seed)
		}
	}
	c.AccessTokenTTL = duration("ACCESS_TOKEN_TTL", 15*time.Minute, &errs)
	c.RefreshTokenTTL = duration("REFRESH_TOKEN_TTL", 60*24*time.Hour, &errs)
	c.RefreshGrace = duration("REFRESH_GRACE", 30*time.Second, &errs)

	c.AppleBundleID = str("APPLE_BUNDLE_ID", "laviosa.branch")
	c.TelegramBotToken = str("TELEGRAM_BOT_TOKEN", "")
	c.TelegramBotUsername = str("TELEGRAM_BOT_USERNAME", "")
	if (c.TelegramBotToken == "") != (c.TelegramBotUsername == "") {
		errs = append(errs, errors.New("TELEGRAM_BOT_TOKEN and TELEGRAM_BOT_USERNAME must be set together"))
	}

	c.PublicBaseURL = str("PUBLIC_BASE_URL", "http://localhost:8080")
	c.AppScheme = str("APP_URL_SCHEME", "vetka")

	if len(errs) > 0 {
		return Config{}, fmt.Errorf("config: %v", errs)
	}
	return c, nil
}

func str(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func integer(key string, def int, errs *[]error) int {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		*errs = append(*errs, fmt.Errorf("%s: want a positive integer, got %q", key, v))
		return def
	}
	return n
}

func duration(key string, def time.Duration, errs *[]error) time.Duration {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		*errs = append(*errs, fmt.Errorf("%s: want a positive duration like 10s, got %q", key, v))
		return def
	}
	return d
}
