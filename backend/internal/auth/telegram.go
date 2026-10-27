package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

type TelegramUser struct {
	ID        int64
	FirstName string
	LastName  string
	Username  string
}

// SignTelegram computes the hash Telegram puts into widget data: every field
// except "hash", sorted as key=value lines, signed with HMAC-SHA256 keyed by
// SHA256(bot_token). Verification compares against it; the local fake login
// uses it to sign data the way Telegram would.
func SignTelegram(data map[string]string, botToken string) string {
	keys := make([]string, 0, len(data))
	for k := range data {
		if k != "hash" {
			keys = append(keys, k)
		}
	}
	slices.Sort(keys)
	lines := make([]string, len(keys))
	for i, k := range keys {
		lines[i] = k + "=" + data[k]
	}
	secret := sha256.Sum256([]byte(botToken))
	mac := hmac.New(sha256.New, secret[:])
	mac.Write([]byte(strings.Join(lines, "\n")))
	return hex.EncodeToString(mac.Sum(nil))
}

// VerifyTelegram checks Telegram Login Widget data as documented in
// https://core.telegram.org/widgets/login#checking-authorization:
// hash = hex(HMAC-SHA256(data_check_string, SHA256(bot_token))).
//
// Every received field except hash is part of the signature, including ones
// we do not know yet, so new widget fields do not break sign-in.
func VerifyTelegram(data map[string]string, botToken string, now time.Time, maxAge time.Duration) (TelegramUser, error) {
	if len(data) > 16 {
		return TelegramUser{}, fmt.Errorf("%w: too many fields", ErrInvalidCredentials)
	}
	hash := data["hash"]
	if hash == "" {
		return TelegramUser{}, fmt.Errorf("%w: missing hash", ErrInvalidCredentials)
	}

	for k, v := range data {
		if len(v) > 512 {
			return TelegramUser{}, fmt.Errorf("%w: field %q too long", ErrInvalidCredentials, k)
		}
	}
	if !hmac.Equal([]byte(SignTelegram(data, botToken)), []byte(strings.ToLower(hash))) {
		return TelegramUser{}, fmt.Errorf("%w: bad signature", ErrInvalidCredentials)
	}

	authDate, err := strconv.ParseInt(data["auth_date"], 10, 64)
	if err != nil {
		return TelegramUser{}, fmt.Errorf("%w: bad auth_date", ErrInvalidCredentials)
	}
	age := now.Sub(time.Unix(authDate, 0))
	if age > maxAge || age < -time.Minute {
		return TelegramUser{}, fmt.Errorf("%w: auth_date out of range", ErrInvalidCredentials)
	}

	id, err := strconv.ParseInt(data["id"], 10, 64)
	if err != nil || id <= 0 {
		return TelegramUser{}, fmt.Errorf("%w: bad id", ErrInvalidCredentials)
	}
	return TelegramUser{
		ID:        id,
		FirstName: data["first_name"],
		LastName:  data["last_name"],
		Username:  data["username"],
	}, nil
}
