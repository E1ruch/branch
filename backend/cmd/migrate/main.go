// Command migrate applies the embedded SQL migrations.
//
//	migrate [up|down|status]   (default: up)
//
// It is a separate binary, not a step of api startup: several api instances
// starting at once must not race on the schema. The Postgres advisory lock
// makes even concurrent migrate runs safe.
package main

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"os"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"

	"vetka/internal/config"
	"vetka/migrations"
)

func main() {
	if err := run(); err != nil {
		slog.Error("migrate failed", slog.Any("err", err))
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	command := "up"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}

	db, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()

	locker, err := lock.NewPostgresSessionLocker()
	if err != nil {
		return err
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS, goose.WithSessionLocker(locker))
	if err != nil {
		return err
	}

	ctx := context.Background()
	switch command {
	case "up":
		results, err := provider.Up(ctx)
		for _, r := range results {
			fmt.Println(r)
		}
		if err == nil && len(results) == 0 {
			fmt.Println("no pending migrations")
		}
		return err
	case "down":
		result, err := provider.Down(ctx)
		if result != nil {
			fmt.Println(result)
		}
		return err
	case "status":
		statuses, err := provider.Status(ctx)
		if err != nil {
			return err
		}
		for _, s := range statuses {
			applied := "pending"
			if !s.AppliedAt.IsZero() {
				applied = s.AppliedAt.Format("2006-01-02 15:04:05")
			}
			fmt.Printf("%05d  %-20s  %s\n", s.Source.Version, applied, s.Source.Path)
		}
		return nil
	default:
		return fmt.Errorf("unknown command %q, want up, down or status", command)
	}
}
