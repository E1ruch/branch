// Package testdb gives integration tests a fresh, fully migrated database.
//
// Tests that need it are skipped unless TEST_DATABASE_URL points at a Postgres
// whose user may create databases (the local Compose one does).
package testdb

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"vetka/migrations"
)

func New(t *testing.T) *pgxpool.Pool {
	t.Helper()
	adminURL := os.Getenv("TEST_DATABASE_URL")
	if adminURL == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()

	admin, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		t.Fatalf("testdb: connect: %v", err)
	}
	defer admin.Close(ctx)

	name := fmt.Sprintf("vetka_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatalf("testdb: create database: %v", err)
	}
	t.Cleanup(func() {
		conn, err := pgx.Connect(context.Background(), adminURL)
		if err != nil {
			t.Errorf("testdb: drop %s: %v", name, err)
			return
		}
		defer conn.Close(context.Background())
		if _, err := conn.Exec(context.Background(), "DROP DATABASE "+name+" WITH (FORCE)"); err != nil {
			t.Errorf("testdb: drop %s: %v", name, err)
		}
	})

	u, err := url.Parse(adminURL)
	if err != nil {
		t.Fatalf("testdb: parse url: %v", err)
	}
	u.Path = "/" + strings.TrimPrefix(name, "/")
	dbURL := u.String()

	migrate(t, dbURL)

	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("testdb: pool: %v", err)
	}
	t.Cleanup(pool.Close) // runs before the drop: cleanups are LIFO
	return pool
}

func migrate(t *testing.T, dbURL string) {
	t.Helper()
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("testdb: open: %v", err)
	}
	defer db.Close()
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS)
	if err != nil {
		t.Fatalf("testdb: goose: %v", err)
	}
	if _, err := provider.Up(context.Background()); err != nil {
		t.Fatalf("testdb: migrate: %v", err)
	}
}
