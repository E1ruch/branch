package auth

import (
	"crypto/rand"
	"strings"
	"unicode/utf8"

	"vetka/internal/user"
)

// usernameCandidates lists names to try for a new account: the preferred one
// (a Telegram username) if it fits our rules, then random ones. The user can
// pick a real name later during onboarding.
func usernameCandidates(preferred string) []string {
	var out []string
	if user.ValidateUsername(preferred) == nil {
		out = append(out, preferred)
	}
	for range 5 {
		out = append(out, "user_"+strings.ToLower(rand.Text()[:8]))
	}
	return out
}

// displayName joins name parts and fits the result into users.display_name.
func displayName(parts ...string) *string {
	var nonEmpty []string
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			nonEmpty = append(nonEmpty, p)
		}
	}
	name := strings.Join(nonEmpty, " ")
	if name == "" {
		return nil
	}
	if utf8.RuneCountInString(name) > 48 {
		name = string([]rune(name)[:48])
	}
	return &name
}
