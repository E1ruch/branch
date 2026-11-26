package httpapi

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"vetka/internal/auth"
	"vetka/internal/comment"
	"vetka/internal/community"
	"vetka/internal/media"
	"vetka/internal/post"
	"vetka/internal/testdb"
	"vetka/internal/user"
)

type mediaObjects struct {
	mu        sync.Mutex
	data      map[string][]byte
	deleteErr error
	publishes int
}

func (s *mediaObjects) PresignUpload(_ context.Context, key, mime string, size int64) (string, map[string]string, error) {
	return "https://uploads.example/" + key, map[string]string{"Content-Type": mime, "Content-Length": fmt.Sprint(size)}, nil
}

func (s *mediaObjects) OpenUpload(_ context.Context, key string) (io.ReadCloser, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, ok := s.data[key]
	if !ok {
		return nil, media.ErrUploadMissing
	}
	return io.NopCloser(bytes.NewReader(data)), nil
}

func (s *mediaObjects) Publish(_ context.Context, key, _ string, data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.publishes++
	s.data[key] = data
	return nil
}

func (s *mediaObjects) Delete(_ context.Context, key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.deleteErr != nil && strings.HasPrefix(key, "images/") {
		return s.deleteErr
	}
	delete(s.data, key)
	return nil
}

func (s *mediaObjects) ImageURL(key string, width int) string {
	return fmt.Sprintf("https://images.example/%d/%s", width, key)
}

func TestMediaAPI(t *testing.T) {
	db := testdb.New(t)
	objects := &mediaObjects{data: make(map[string][]byte)}
	svc := media.NewService(db, objects, nil)
	_, key, _ := ed25519.GenerateKey(nil)
	issuer := auth.NewIssuer(key, time.Hour)
	c := client{t, NewRouter(Deps{
		Logger: discard, RequestTimeout: 5 * time.Second,
		Auth:  auth.NewService(db, issuer, nil, nil, auth.Config{}, discard),
		Users: user.NewStore(db), Communities: community.NewService(db),
		Posts: post.NewService(db, allowAll{}), Comments: comment.NewService(db, allowAll{}), Media: svc,
	})}
	ownerID := testdb.CreateUser(t, db, "uploader")
	owner, _, _ := issuer.Issue(ownerID)
	other, _, _ := issuer.Issue(testdb.CreateUser(t, db, "observer"))
	expect := func(method, path, token string, request any, want int) map[string]any {
		t.Helper()
		status, response := c.call(method, path, token, request)
		if status != want {
			t.Fatalf("%s %s: got %d %v, want %d", method, path, status, response, want)
		}
		return response
	}

	var raw bytes.Buffer
	imageData := image.NewNRGBA(image.Rect(0, 0, 12, 9))
	imageData.Set(9, 5, color.NRGBA{R: 230, A: 127})
	if err := png.Encode(&raw, imageData); err != nil {
		t.Fatal(err)
	}

	startUpload := func(mime string) (int64, string) {
		t.Helper()
		response := expect("POST", "/v1/media/uploads", owner, map[string]any{"mime_type": mime, "size_bytes": raw.Len()}, http.StatusCreated)
		staging, ok := strings.CutPrefix(response["upload_url"].(string), "https://uploads.example/")
		if !ok || !strings.HasPrefix(staging, "uploads/") {
			t.Fatalf("invalid staging path: %q", staging)
		}
		if response["headers"].(map[string]any)["Content-Length"] != fmt.Sprint(raw.Len()) {
			t.Fatalf("invalid upload headers: %v", response["headers"])
		}
		return int64(response["id"].(float64)), staging
	}
	completePath := func(id int64) string { return fmt.Sprintf("/v1/media/%d/complete", id) }
	expect("POST", "/v1/media/uploads", "", nil, http.StatusUnauthorized)
	expect("POST", "/v1/media/uploads", owner, map[string]any{"mime_type": "image/png", "size_bytes": media.MaxBytes + 1}, http.StatusUnprocessableEntity)
	wrong, wrongStaging := startUpload("image/jpeg")
	objects.data[wrongStaging] = raw.Bytes()
	if code := errCode(expect("POST", completePath(wrong), owner, nil, http.StatusUnprocessableEntity)); code != "invalid_media" {
		t.Fatalf("wrong declared MIME error: %s", code)
	}

	first, firstStaging := startUpload("image/png")
	expect("POST", completePath(first), owner, nil, http.StatusConflict)
	expect("POST", completePath(first), other, nil, http.StatusNotFound)
	objects.data[firstStaging] = raw.Bytes()
	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			got, err := svc.Complete(t.Context(), ownerID, first)
			if err != nil || got.Width != 12 || got.Height != 9 {
				t.Errorf("concurrent completion = %+v, %v", got, err)
			}
		})
	}
	wg.Wait()
	if objects.publishes != 1 {
		t.Fatalf("published %d times, want 1", objects.publishes)
	}
	firstDTO := expect("POST", completePath(first), owner, nil, http.StatusOK)
	if hash, err := base64.StdEncoding.DecodeString(firstDTO["thumbhash"].(string)); err != nil || len(hash) < 5 {
		t.Fatalf("invalid ThumbHash: %x, %v", hash, err)
	}
	urls := firstDTO["urls"].(map[string]any)
	if len(urls) != 4 || !strings.Contains(urls["640"].(string), "/640/images/") {
		t.Fatalf("invalid media URLs: %v", urls)
	}
	// Reusing the live PUT URL must not replace the public object.
	objects.data[firstStaging] = []byte("different staging data")
	expect("POST", completePath(first), owner, nil, http.StatusOK)
	for path, data := range objects.data {
		if strings.HasPrefix(path, "images/") && !bytes.Equal(data, raw.Bytes()) {
			t.Fatalf("final bytes changed after staging was overwritten")
		}
	}

	second, secondStaging := startUpload("image/png")
	objects.data[secondStaging] = raw.Bytes()
	expect("POST", completePath(second), owner, nil, http.StatusOK)
	expect("POST", "/v1/communities", owner, map[string]any{"slug": "photos", "title": "Photos"}, http.StatusCreated)
	expect("PATCH", "/v1/me", other, map[string]any{"avatar_media_id": first}, http.StatusUnprocessableEntity)
	me := expect("PATCH", "/v1/me", owner, map[string]any{"avatar_media_id": first}, http.StatusOK)
	avatar := me["avatar_url"]
	if avatar != urls["320"] {
		t.Fatalf("profile avatar = %v, want %v", avatar, urls["320"])
	}
	expect("PATCH", "/v1/communities/photos", other, map[string]any{"banner_media_id": first}, http.StatusForbidden)
	response := expect("PATCH", "/v1/communities/photos", owner, map[string]any{"icon_media_id": first, "banner_media_id": second}, http.StatusOK)
	if response["can_edit"] != true || response["icon_url"] != avatar || response["banner_url"] == nil {
		t.Fatalf("moderator detail with images: %v", response)
	}
	response = expect("GET", "/v1/communities/photos", other, nil, http.StatusOK)
	if response["can_edit"] != false {
		t.Fatalf("non-moderator detail: %v", response)
	}

	const createPost = "/v1/communities/photos/posts"
	expect("POST", createPost, other, map[string]any{"title": "Foreign image", "media_ids": []int64{first}}, http.StatusUnprocessableEntity)
	expect("POST", createPost, owner, map[string]any{"title": "Duplicate image", "media_ids": []int64{first, first}}, http.StatusUnprocessableEntity)
	response = expect("POST", createPost, owner, map[string]any{"title": "Gallery entry", "media_ids": []int64{second, first}}, http.StatusCreated)
	postID := int64(response["id"].(float64))
	checkPost := func(response map[string]any) {
		t.Helper()
		images := response["media"].([]any)
		if len(images) != 2 || images[0].(map[string]any)["id"] != float64(second) || images[1].(map[string]any)["id"] != float64(first) {
			t.Fatalf("post images out of order: %v", images)
		}
		if response["author"].(map[string]any)["avatar_url"] != avatar {
			t.Fatalf("missing post author avatar: %v", response["author"])
		}
	}
	checkPost(response)
	expect("POST", createPost, owner, map[string]any{"title": "Already posted image", "media_ids": []int64{first}}, http.StatusUnprocessableEntity)
	postPath := fmt.Sprintf("/v1/posts/%d", postID)
	checkPost(expect("GET", postPath, "", nil, http.StatusOK))
	for _, path := range []string{"/v1/feed/all", "/v1/search/posts?q=Gallery", "/v1/users/uploader/posts"} {
		t.Run(path, func(t *testing.T) {
			feed := expect("GET", path, "", nil, http.StatusOK)["items"].([]any)
			if len(feed) != 1 {
				t.Fatalf("unexpected results: %v", feed)
			}
			checkPost(feed[0].(map[string]any))
		})
	}
	commentBody := expect("POST", postPath+"/comments", owner, map[string]any{"body": "Nice"}, http.StatusCreated)
	if commentBody["author"].(map[string]any)["avatar_url"] != avatar {
		t.Fatalf("missing comment author avatar: %v", commentBody)
	}
	if got := expect("PATCH", "/v1/me", owner, map[string]any{"avatar_media_id": 0}, http.StatusOK)["avatar_url"]; got != nil {
		t.Fatalf("avatar not cleared: %v", got)
	}
	response = expect("PATCH", "/v1/communities/photos", owner, map[string]any{"icon_media_id": 0}, http.StatusOK)
	if response["icon_url"] != nil || response["banner_url"] == nil {
		t.Fatalf("clearing icon also changed banner: %v", response)
	}

	third, thirdStaging := startUpload("image/png")
	objects.data[thirdStaging] = raw.Bytes()
	expect("POST", completePath(third), owner, nil, http.StatusOK)
	photoPost := expect("POST", createPost, owner, map[string]any{"media_ids": []int64{third}}, http.StatusCreated)
	if photoPost["title"] != "" || photoPost["body"] != "" || len(photoPost["media"].([]any)) != 1 {
		t.Fatalf("photo-only post: %v", photoPost)
	}
	expect("PATCH", fmt.Sprintf("/v1/posts/%d", int64(photoPost["id"].(float64))), owner,
		map[string]any{"body": ""}, http.StatusOK)
}

func TestMediaSweepBlocksAttachmentAfterObjectFailure(t *testing.T) {
	db := testdb.New(t)
	ctx := t.Context()
	ownerID := testdb.CreateUser(t, db, "uploader")
	objects := &mediaObjects{data: make(map[string][]byte)}
	svc := media.NewService(db, objects, nil)
	var raw bytes.Buffer
	if err := png.Encode(&raw, image.NewGray(image.Rect(0, 0, 1, 1))); err != nil {
		t.Fatal(err)
	}
	ready := func() (media.Image, string) {
		t.Helper()
		upload, err := svc.BeginUpload(ctx, ownerID, "image/png", int64(raw.Len()))
		if err != nil {
			t.Fatal(err)
		}
		staging := strings.TrimPrefix(upload.URL, "https://uploads.example/")
		objects.data[staging] = raw.Bytes()
		img, err := svc.Complete(ctx, ownerID, upload.ID)
		if err != nil {
			t.Fatal(err)
		}
		return img, staging
	}
	attached, attachedStaging := ready()
	orphan, orphanStaging := ready()
	deletedPostImage, deletedPostStaging := ready()
	banner, bannerStaging := ready()
	communities := community.NewService(db)
	if _, err := communities.Create(ctx, ownerID, community.CreateInput{Slug: "photos", Title: "Photos"}); err != nil {
		t.Fatal(err)
	}
	if _, err := communities.Update(ctx, "photos", ownerID, community.UpdateInput{BannerMediaID: &banner.ID}); err != nil {
		t.Fatal(err)
	}
	posts := post.NewService(db, allowAll{})
	deletedPost, err := posts.Create(ctx, ownerID, "photos", post.CreateInput{
		Title: "Eventually deleted", MediaIDs: []int64{deletedPostImage.ID, banner.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := posts.Delete(ctx, deletedPost.ID, ownerID); err != nil {
		t.Fatal(err)
	}
	users := user.NewStore(db)
	if _, err := users.Update(ctx, ownerID, user.UpdateInput{AvatarMediaID: &attached.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `UPDATE media SET created_at = now() - interval '2 days', publish_started_at = NULL`); err != nil {
		t.Fatal(err)
	}

	objects.deleteErr = errors.New("object storage unavailable for deletion")
	if err := svc.Sweep(ctx); !errors.Is(err, objects.deleteErr) {
		t.Fatalf("expected object deletion error, got %v", err)
	}
	if _, err := svc.Complete(ctx, ownerID, orphan.ID); !errors.Is(err, media.ErrNotFound) {
		t.Fatalf("marked orphan is still exposed: %v", err)
	}
	if _, err := users.Update(ctx, ownerID, user.UpdateInput{AvatarMediaID: &orphan.ID}); err == nil {
		t.Fatal("marked orphan is still attachable")
	}

	objects.deleteErr = nil
	if err := svc.Sweep(ctx); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{attached.Key, banner.Key} {
		if _, ok := objects.data[key]; !ok {
			t.Fatalf("attached image %s was deleted", key)
		}
	}
	for _, key := range []string{orphan.Key, orphanStaging, attachedStaging, bannerStaging, deletedPostImage.Key, deletedPostStaging} {
		if _, ok := objects.data[key]; ok {
			t.Fatalf("object %s leaked", key)
		}
	}
	var orphanExists bool
	if err := db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM media WHERE id = $1)`, orphan.ID).Scan(&orphanExists); err != nil || orphanExists {
		t.Fatalf("orphan row remains: %v, %v", orphanExists, err)
	}
}
