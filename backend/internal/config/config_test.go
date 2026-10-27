package config

import (
	"strings"
	"testing"
)

func TestFakeTelegramLoginOnlyLocally(t *testing.T) {
	t.Setenv("TELEGRAM_BOT_TOKEN", "dev-fake-token")
	t.Setenv("TELEGRAM_BOT_USERNAME", "vetka_dev_bot")
	t.Setenv("TELEGRAM_FAKE_LOGIN", "true")

	t.Setenv("PUBLIC_BASE_URL", "http://192.168.1.20:8080") // a phone on the LAN
	if c, err := Load(); err != nil || !c.TelegramFakeLogin {
		t.Errorf("local http: %v", err)
	}

	t.Setenv("PUBLIC_BASE_URL", "https://api.vetka.app")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "local development only") {
		t.Errorf("https must refuse fake login, got %v", err)
	}
}
