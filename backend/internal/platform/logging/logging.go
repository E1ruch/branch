// Package logging builds the process-wide slog logger.
package logging

import (
	"log/slog"
	"os"
)

// New returns a text logger for local runs and a JSON one for log collectors.
func New(level slog.Level, json bool) *slog.Logger {
	opts := &slog.HandlerOptions{Level: level}
	if json {
		return slog.New(slog.NewJSONHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewTextHandler(os.Stdout, opts))
}
