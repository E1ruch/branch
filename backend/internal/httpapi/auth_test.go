package httpapi

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"vetka/internal/auth"
	"vetka/internal/testdb"
	"vetka/internal/user"
)

const testBotToken = "123456:TEST-token"

type memReplay struct{ seen map[string]bool }

func (m *memReplay) Claim(_ context.Context, key string, _ time.Duration) (bool, error) {
	if m.seen[key] {
		return false, nil
	}
	m.seen[key] = true
	return true, nil
}

func signedTelegram(id int64, username string) map[string]string {
	data := map[string]string{
		"id":        strconv.FormatInt(id, 10),
		"username":  username,
		"auth_date": strconv.FormatInt(time.Now().Unix(), 10),
	}
	keys := slices.Sorted(maps.Keys(data))
	lines := make([]string, len(keys))
	for i, k := range keys {
		lines[i] = k + "=" + data[k]
	}
	secret := sha256.Sum256([]byte(testBotToken))
	mac := hmac.New(sha256.New, secret[:])
	mac.Write([]byte(strings.Join(lines, "\n")))
	data["hash"] = hex.EncodeToString(mac.Sum(nil))
	return data
}

type client struct {
	t *testing.T
	h http.Handler
}

func (c client) call(method, path, token string, body any) (int, map[string]any) {
	c.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	c.h.ServeHTTP(rec, req)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func errCode(body map[string]any) string {
	e, _ := body["error"].(map[string]any)
	code, _ := e["code"].(string)
	return code
}

func TestAuthFlowEndToEnd(t *testing.T) {
	db := testdb.New(t)
	_, key, _ := ed25519.GenerateKey(nil)
	svc := auth.NewService(db, auth.NewIssuer(key, 15*time.Minute), auth.NewAppleVerifier("laviosa.branch"),
		&memReplay{seen: map[string]bool{}},
		auth.Config{RefreshTTL: time.Hour, RefreshGrace: 30 * time.Second, TelegramBotToken: testBotToken, TelegramMaxAge: time.Hour},
		discard)
	c := client{t, NewRouter(Deps{Logger: discard, RequestTimeout: 5 * time.Second, Auth: svc, Users: user.NewStore(db)})}

	status, session := c.call("POST", "/v1/auth/telegram", "", map[string]any{"data": signedTelegram(42, "ivan_tg"), "device_name": "iPhone"})
	if status != http.StatusOK || session["is_new_user"] != true {
		t.Fatalf("sign-in: %d %v", status, session)
	}
	access := session["access_token"].(string)
	refresh := session["refresh_token"].(string)

	status, me := c.call("GET", "/v1/me", access, nil)
	if status != http.StatusOK || me["username"] != "ivan_tg" {
		t.Errorf("/me: %d %v", status, me)
	}

	if status, body := c.call("GET", "/v1/me", "", nil); status != http.StatusUnauthorized || errCode(body) != "unauthorized" {
		t.Errorf("/me anonymous: %d %v", status, body)
	}
	if status, body := c.call("GET", "/v1/me", "garbage", nil); status != http.StatusUnauthorized || errCode(body) != "unauthorized" {
		t.Errorf("/me bad token: %d %v", status, body)
	}

	status, tokens := c.call("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": refresh})
	if status != http.StatusOK || tokens["refresh_token"] == refresh {
		t.Fatalf("refresh: %d %v", status, tokens)
	}
	newRefresh := tokens["refresh_token"].(string)

	if status, _ := c.call("POST", "/v1/auth/logout", "", map[string]string{"refresh_token": newRefresh}); status != http.StatusNoContent {
		t.Errorf("logout: %d", status)
	}
	if status, body := c.call("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": newRefresh}); status != http.StatusUnauthorized || errCode(body) != "refresh_invalid" {
		t.Errorf("refresh after logout: %d %v", status, body)
	}

	if status, body := c.call("POST", "/v1/auth/telegram", "", map[string]any{"data": map[string]string{"id": "1", "hash": "00"}}); status != http.StatusUnauthorized || errCode(body) != "invalid_credentials" {
		t.Errorf("forged telegram: %d %v", status, body)
	}
}

func TestAuthenticateMiddleware(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, signedIn := auth.UserID(r.Context())
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "signed_in": signedIn})
	})
	verify := func(token string) (int64, error) {
		switch token {
		case "good":
			return 7, nil
		case "expired":
			return 0, auth.ErrTokenExpired
		}
		return 0, errors.New("bad")
	}
	h := authenticate(verify)(ok)

	tests := []struct {
		header string
		status int
		code   string
	}{
		{"", http.StatusOK, ""},
		{"Bearer good", http.StatusOK, ""},
		{"Bearer expired", http.StatusUnauthorized, "token_expired"},
		{"Bearer bad", http.StatusUnauthorized, "unauthorized"},
		{"Basic Zm9vOmJhcg==", http.StatusUnauthorized, "unauthorized"},
	}
	for _, tt := range tests {
		t.Run(tt.header, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/", nil)
			if tt.header != "" {
				req.Header.Set("Authorization", tt.header)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			var body map[string]any
			json.Unmarshal(rec.Body.Bytes(), &body)
			if rec.Code != tt.status || errCode(body) != tt.code {
				t.Errorf("got %d %v, want %d %q", rec.Code, body, tt.status, tt.code)
			}
		})
	}
}

func TestTelegramWebFlow(t *testing.T) {
	h := NewRouter(Deps{Logger: discard, RequestTimeout: time.Second,
		TelegramBot: "vetka_bot", PublicBaseURL: "https://api.vetka.example/", AppScheme: "vetka"})

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/auth/telegram", nil))
	page := rec.Body.String()
	if rec.Code != http.StatusOK ||
		!strings.Contains(page, `data-telegram-login="vetka_bot"`) ||
		!strings.Contains(page, `data-auth-url="https://api.vetka.example/auth/telegram/callback"`) {
		t.Errorf("page: %d\n%s", rec.Code, page)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/auth/telegram/callback?id=42&auth_date=1&hash=abc", nil))
	if loc := rec.Header().Get("Location"); rec.Code != http.StatusFound || loc != "vetka://auth/telegram?id=42&auth_date=1&hash=abc" {
		t.Errorf("callback: %d %q", rec.Code, loc)
	}

	disabled := NewRouter(Deps{Logger: discard, RequestTimeout: time.Second})
	rec = httptest.NewRecorder()
	disabled.ServeHTTP(rec, httptest.NewRequest("GET", "/auth/telegram", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("disabled page: %d, want 404", rec.Code)
	}
}

func TestFakeTelegramLogin(t *testing.T) {
	h := NewRouter(Deps{Logger: discard, RequestTimeout: time.Second,
		TelegramBot: "vetka_dev_bot", TelegramToken: testBotToken, TelegramFake: true,
		PublicBaseURL: "http://localhost:8080", AppScheme: "vetka"})

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/auth/telegram", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `action="/auth/telegram/fake"`) ||
		strings.Contains(rec.Body.String(), "telegram-widget.js") {
		t.Fatalf("fake page: %d\n%s", rec.Code, rec.Body.String())
	}

	form := url.Values{"id": {"4242"}, "username": {"dev_ivan"}, "first_name": {"Иван"}}
	req := httptest.NewRequest("POST", "/auth/telegram/fake", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	loc, _ := url.Parse(rec.Header().Get("Location"))
	if rec.Code != http.StatusSeeOther || loc.Path != "/auth/telegram/callback" {
		t.Fatalf("submit: %d %q", rec.Code, rec.Header().Get("Location"))
	}

	// The data must pass the production check, unchanged.
	data := map[string]string{}
	for k := range loc.Query() {
		data[k] = loc.Query().Get(k)
	}
	u, err := auth.VerifyTelegram(data, testBotToken, time.Now(), time.Hour)
	if err != nil || u.ID != 4242 || u.Username != "dev_ivan" || u.FirstName != "Иван" {
		t.Fatalf("verify: %+v, %v", u, err)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", loc.RequestURI(), nil))
	if app := rec.Header().Get("Location"); rec.Code != http.StatusFound || !strings.HasPrefix(app, "vetka://auth/telegram?") {
		t.Errorf("callback: %d %q", rec.Code, app)
	}

	off := NewRouter(Deps{Logger: discard, RequestTimeout: time.Second,
		TelegramBot: "vetka_bot", TelegramToken: testBotToken, PublicBaseURL: "https://api.vetka.app", AppScheme: "vetka"})
	rec = httptest.NewRecorder()
	off.ServeHTTP(rec, httptest.NewRequest("POST", "/auth/telegram/fake", strings.NewReader(form.Encode())))
	if rec.Code != http.StatusNotFound {
		t.Errorf("fake submit with the flag off: %d, want 404", rec.Code)
	}
}

func TestPasswordAuthAPI(t *testing.T) {
	db := testdb.New(t)
	_, key, _ := ed25519.GenerateKey(nil)
	svc := auth.NewService(db, auth.NewIssuer(key, 15*time.Minute), nil, nil,
		auth.Config{RefreshTTL: time.Hour, RefreshGrace: 30 * time.Second}, discard)
	c := client{t, NewRouter(Deps{Logger: discard, RequestTimeout: 5 * time.Second, Auth: svc, Users: user.NewStore(db)})}

	status, session := c.call("POST", "/v1/auth/register", "", map[string]any{"username": "ivan", "password": "secret-pass", "device_name": "iPhone"})
	if status != http.StatusCreated || session["is_new_user"] != false || session["user"].(map[string]any)["username"] != "ivan" {
		t.Fatalf("register: %d %v", status, session)
	}
	if status, me := c.call("GET", "/v1/me", session["access_token"].(string), nil); status != http.StatusOK || me["username"] != "ivan" {
		t.Errorf("me after register: %d %v", status, me)
	}

	tests := []struct {
		path   string
		body   map[string]any
		status int
		code   string
		field  string
	}{
		{"/v1/auth/register", map[string]any{"username": "IVAN", "password": "secret-pass"}, http.StatusConflict, "username_taken", "username"},
		{"/v1/auth/register", map[string]any{"username": "petr", "password": "short"}, http.StatusUnprocessableEntity, "validation_failed", "password"},
		{"/v1/auth/register", map[string]any{"username": "ab", "password": "secret-pass"}, http.StatusUnprocessableEntity, "validation_failed", "username"},
		{"/v1/auth/login", map[string]any{"username": "ivan", "password": "wrong-pass"}, http.StatusUnauthorized, "invalid_credentials", ""},
		{"/v1/auth/login", map[string]any{"username": "nobody", "password": "secret-pass"}, http.StatusUnauthorized, "invalid_credentials", ""},
		{"/v1/auth/login", map[string]any{"username": "Ivan", "password": "secret-pass"}, http.StatusOK, "", ""},
	}
	for _, tt := range tests {
		status, body := c.call("POST", tt.path, "", tt.body)
		e, _ := body["error"].(map[string]any)
		field, _ := e["field"].(string)
		if status != tt.status || errCode(body) != tt.code || field != tt.field {
			t.Errorf("%s %v: %d %v", tt.path, tt.body, status, body)
		}
	}
}
