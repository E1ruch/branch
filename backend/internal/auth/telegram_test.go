package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"maps"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testBotToken = "123456:TEST-token"

// signTelegram signs data the way Telegram does, for tests that need fresh
// payloads. TestTelegramGoldenVector pins the algorithm itself.
func signTelegram(data map[string]string, botToken string) map[string]string {
	keys := slices.Sorted(maps.Keys(data))
	lines := make([]string, len(keys))
	for i, k := range keys {
		lines[i] = k + "=" + data[k]
	}
	secret := sha256.Sum256([]byte(botToken))
	mac := hmac.New(sha256.New, secret[:])
	mac.Write([]byte(strings.Join(lines, "\n")))

	out := maps.Clone(data)
	out["hash"] = hex.EncodeToString(mac.Sum(nil))
	return out
}

func telegramData(id int64, username string, at time.Time) map[string]string {
	return signTelegram(map[string]string{
		"id":         strconv.FormatInt(id, 10),
		"first_name": "Иван",
		"username":   username,
		"auth_date":  strconv.FormatInt(at.Unix(), 10),
	}, testBotToken)
}

func TestTelegramGoldenVector(t *testing.T) {
	// Hash computed by an independent Python implementation of
	// https://core.telegram.org/widgets/login#checking-authorization.
	data := map[string]string{
		"id":         "42",
		"first_name": "Иван",
		"username":   "ivan_petrov",
		"auth_date":  "1793000000",
		"hash":       "48bd2e6794852c7c4f54136fc0895f7b4b3e3b943565b523e5e1ad6bf2e729b7",
	}
	now := time.Unix(1793000000, 0).Add(time.Minute)

	u, err := VerifyTelegram(data, testBotToken, now, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if u.ID != 42 || u.Username != "ivan_petrov" || u.FirstName != "Иван" {
		t.Errorf("user = %+v", u)
	}
}

func TestTelegramRejects(t *testing.T) {
	now := time.Now()
	valid := telegramData(42, "ivan", now)

	tests := []struct {
		name   string
		data   map[string]string
		token  string
		maxAge time.Duration
	}{
		{"wrong bot token", valid, "999:other", time.Hour},
		{"changed field", with(valid, "id", "43"), testBotToken, time.Hour},
		{"added field", with(valid, "username", "admin"), testBotToken, time.Hour},
		{"missing hash", with(valid, "hash", ""), testBotToken, time.Hour},
		{"too old", telegramData(42, "ivan", now.Add(-2*time.Hour)), testBotToken, time.Hour},
		{"from the future", telegramData(42, "ivan", now.Add(time.Hour)), testBotToken, time.Hour},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := VerifyTelegram(tt.data, tt.token, now, tt.maxAge)
			if !errors.Is(err, ErrInvalidCredentials) {
				t.Errorf("err = %v, want ErrInvalidCredentials", err)
			}
		})
	}
}

func TestTelegramUnknownFieldsAreSigned(t *testing.T) {
	now := time.Now()
	data := telegramData(42, "ivan", now)
	delete(data, "hash")
	data["new_field_from_telegram"] = "x"
	if _, err := VerifyTelegram(signTelegram(data, testBotToken), testBotToken, now, time.Hour); err != nil {
		t.Errorf("a new signed field must not break sign-in: %v", err)
	}
}

func with(m map[string]string, k, v string) map[string]string {
	out := maps.Clone(m)
	out[k] = v
	return out
}
