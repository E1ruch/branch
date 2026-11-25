package httpapi

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"vetka/internal/media"
)

type mediaHandlers struct {
	svc *media.Service
	log *slog.Logger
}

type imageDTO struct {
	ID        int64             `json:"id"`
	Width     int               `json:"width"`
	Height    int               `json:"height"`
	ThumbHash []byte            `json:"thumbhash"`
	URLs      map[string]string `json:"urls"`
}

func toImageDTO(img media.Image, svc *media.Service) imageDTO {
	urls := make(map[string]string, 4)
	for _, width := range [...]int{320, 640, 1080, 1440} {
		urls[strconv.Itoa(width)] = svc.ImageURL(img.Key, width)
	}
	return imageDTO{ID: img.ID, Width: img.Width, Height: img.Height, ThumbHash: img.ThumbHash, URLs: urls}
}

func toImageDTOs(images []media.Image, svc *media.Service) []imageDTO {
	if svc == nil {
		return []imageDTO{}
	}
	out := make([]imageDTO, len(images))
	for i, img := range images {
		out[i] = toImageDTO(img, svc)
	}
	return out
}

func optionalImageURL(svc *media.Service, key *string, width int) string {
	if key == nil {
		return ""
	}
	return svc.ImageURL(*key, width)
}

func (h *mediaHandlers) begin(w http.ResponseWriter, r *http.Request) {
	if h.svc == nil {
		writeError(w, http.StatusServiceUnavailable, "media_unavailable", "media uploads are unavailable")
		return
	}
	var req struct {
		MIMEType  string `json:"mime_type"`
		SizeBytes int64  `json:"size_bytes"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	upload, err := h.svc.BeginUpload(r.Context(), viewer(r), req.MIMEType, req.SizeBytes)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, upload)
}

func (h *mediaHandlers) complete(w http.ResponseWriter, r *http.Request) {
	if h.svc == nil {
		writeError(w, http.StatusServiceUnavailable, "media_unavailable", "media uploads are unavailable")
		return
	}
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		h.fail(w, r, media.ErrNotFound)
		return
	}
	img, err := h.svc.Complete(r.Context(), viewer(r), id)
	if err != nil {
		h.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toImageDTO(img, h.svc))
}

func (h *mediaHandlers) fail(w http.ResponseWriter, r *http.Request, err error) {
	var input *media.InputError
	switch {
	case errors.As(err, &input):
		writeFieldError(w, http.StatusUnprocessableEntity, "validation_failed", input.Field, input.Message)
	case errors.Is(err, media.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "media upload not found")
	case errors.Is(err, media.ErrUploadMissing):
		writeError(w, http.StatusConflict, "upload_missing", "image has not been uploaded")
	case errors.Is(err, media.ErrRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many image uploads, try again later")
	case errors.Is(err, media.ErrInvalidImage):
		writeError(w, http.StatusUnprocessableEntity, "invalid_media", "the upload does not match the declared image")
	default:
		internalError(w, r, h.log, err)
	}
}
