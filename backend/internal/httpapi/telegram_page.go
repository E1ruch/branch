package httpapi

import (
	"html/template"
	"math/rand/v2"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"vetka/internal/auth"
)

// --- Telegram web flow -----------------------------------------------------
//
// The app opens /auth/telegram in ASWebAuthenticationSession. The page shows
// the Telegram Login Widget, which redirects to /auth/telegram/callback with
// signed query parameters. The callback forwards them unchanged to the app's
// URL scheme; the app then POSTs them to /v1/auth/telegram for verification.
//
// With fake login on (local development only), the page is a plain form and
// the server signs the data with the configured bot token, exactly as
// Telegram would. Everything after that — callback, redirect to the app,
// signature check, replay guard — is the production path.

type telegramPage struct {
	botUsername   string // empty disables the flow
	botToken      string // signs fake logins
	fake          bool
	publicBaseURL string
	appScheme     string
}

func (p telegramPage) callbackURL() string {
	return strings.TrimRight(p.publicBaseURL, "/") + "/auth/telegram/callback"
}

var telegramPageTmpl = template.Must(template.New("tg").Parse(`<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Вход через Telegram</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         font-family: -apple-system, system-ui, sans-serif; background: Canvas; }
</style>
</head>
<body>
<script async src="https://telegram.org/js/telegram-widget.js?22"
        data-telegram-login="{{.Bot}}" data-size="large" data-radius="12"
        data-auth-url="{{.CallbackURL}}"></script>
</body>
</html>
`))

var fakeTelegramPageTmpl = template.Must(template.New("tg-fake").Parse(`<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Вход через Telegram (локально)</title>
<style>
  :root { color-scheme: light dark; --tg: #2AABEE; }
  body { margin: 0; padding: 24px 20px; font: 17px -apple-system, system-ui, sans-serif; background: Canvas; color: CanvasText; }
  .note { padding: 12px 14px; border-radius: 12px; background: color-mix(in srgb, orange 18%, Canvas); font-size: 15px; }
  label { display: block; margin-top: 18px; font-size: 14px; opacity: .7; }
  input { width: 100%; box-sizing: border-box; margin-top: 6px; padding: 12px; font: inherit;
          border: 1px solid color-mix(in srgb, CanvasText 20%, Canvas); border-radius: 10px; background: Canvas; color: inherit; }
  button { width: 100%; margin-top: 28px; padding: 14px; font: 600 17px -apple-system, system-ui, sans-serif;
           color: white; background: var(--tg); border: 0; border-radius: 12px; }
</style>
</head>
<body>
<p class="note">Локальная разработка: настоящий Telegram не используется. Сервер подпишет данные тестовым токеном бота.</p>
<form method="post" action="/auth/telegram/fake">
  <label for="id">Telegram ID (тот же ID — тот же аккаунт)</label>
  <input id="id" name="id" inputmode="numeric" value="{{.ID}}">
  <label for="username">Ник в Telegram</label>
  <input id="username" name="username" autocapitalize="none" autocorrect="off" value="{{.Username}}">
  <label for="first_name">Имя</label>
  <input id="first_name" name="first_name" value="Тестовый">
  <button type="submit">Войти как тестовый пользователь</button>
</form>
</body>
</html>
`))

func (p telegramPage) page(w http.ResponseWriter, _ *http.Request) {
	if p.botUsername == "" {
		writeError(w, http.StatusNotFound, "provider_disabled", "this sign-in method is disabled")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if p.fake {
		// A fresh ID by default, so every login is a sign-up (handy for
		// onboarding); type a fixed ID to come back to the same account.
		id := 1_000_000 + rand.IntN(9_000_000)
		_ = fakeTelegramPageTmpl.Execute(w, struct {
			ID       int
			Username string
		}{id, "dev_" + strconv.Itoa(id%10000)})
		return
	}
	_ = telegramPageTmpl.Execute(w, struct{ Bot, CallbackURL string }{p.botUsername, p.callbackURL()})
}

// fakeSubmit signs the form the way Telegram signs widget data and sends the
// browser down the real callback path.
func (p telegramPage) fakeSubmit(w http.ResponseWriter, r *http.Request) {
	if !p.fake || p.botUsername == "" {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	if err := r.ParseForm(); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "malformed form")
		return
	}
	data := map[string]string{"auth_date": strconv.FormatInt(time.Now().Unix(), 10)}
	for _, key := range []string{"id", "username", "first_name"} {
		if v := strings.TrimSpace(r.PostForm.Get(key)); v != "" {
			data[key] = v
		}
	}
	data["hash"] = auth.SignTelegram(data, p.botToken)

	q := url.Values{}
	for k, v := range data {
		q.Set(k, v)
	}
	http.Redirect(w, r, p.callbackURL()+"?"+q.Encode(), http.StatusSeeOther)
}

func (p telegramPage) callback(w http.ResponseWriter, r *http.Request) {
	if p.botUsername == "" || r.URL.Query().Get("hash") == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "missing Telegram data")
		return
	}
	target := url.URL{Scheme: p.appScheme, Host: "auth", Path: "/telegram", RawQuery: r.URL.RawQuery}
	http.Redirect(w, r, target.String(), http.StatusFound)
}
