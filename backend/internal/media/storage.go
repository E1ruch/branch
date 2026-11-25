package media

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

const uploadLifetime = 10 * time.Minute

type StorageConfig struct {
	Endpoint       string
	UploadEndpoint string
	Bucket         string
	Region         string
	AccessKey      string
	SecretKey      string
	SessionToken   string
	PathStyle      bool
	ImageProxyURL  string
	ImageProxyKey  string
	ImageProxySalt string
}

type Storage struct {
	objects   *minio.Client
	presigner *minio.Client
	bucket    string
	imageBase string
	imageKey  []byte
	imageSalt []byte
}

func NewStorage(cfg StorageConfig) (*Storage, error) {
	if cfg.Bucket == "" || cfg.Region == "" || cfg.AccessKey == "" || cfg.SecretKey == "" {
		return nil, errors.New("media requires a bucket, region and S3 credentials")
	}
	imageBase, err := endpointURL(cfg.ImageProxyURL)
	if err != nil {
		return nil, fmt.Errorf("media image proxy: %w", err)
	}
	key, keyErr := hex.DecodeString(cfg.ImageProxyKey)
	salt, saltErr := hex.DecodeString(cfg.ImageProxySalt)
	if keyErr != nil || saltErr != nil || len(key) < 16 || len(salt) < 16 {
		return nil, errors.New("media imgproxy key and salt must each be at least 16 bytes encoded as hex")
	}
	objects, err := newS3Client(cfg, cfg.Endpoint)
	if err != nil {
		return nil, fmt.Errorf("media S3 endpoint: %w", err)
	}
	presigner := objects
	if cfg.UploadEndpoint != "" && cfg.UploadEndpoint != cfg.Endpoint {
		presigner, err = newS3Client(cfg, cfg.UploadEndpoint)
		if err != nil {
			return nil, fmt.Errorf("media S3 upload endpoint: %w", err)
		}
	}

	return &Storage{
		objects: objects, presigner: presigner, bucket: cfg.Bucket,
		imageBase: strings.TrimRight(imageBase.String(), "/"), imageKey: key, imageSalt: salt,
	}, nil
}

func endpointURL(value string) (*url.URL, error) {
	u, err := url.Parse(value)
	if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("expected an HTTP(S) endpoint")
	}
	return u, nil
}

func newS3Client(cfg StorageConfig, endpoint string) (*minio.Client, error) {
	u, err := endpointURL(endpoint)
	if err != nil {
		return nil, err
	}
	if u.Path != "" && u.Path != "/" {
		return nil, errors.New("S3 endpoint must have no path")
	}
	opts := &minio.Options{
		Creds:  credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, cfg.SessionToken),
		Secure: u.Scheme == "https",
		Region: cfg.Region,
	}
	if cfg.PathStyle {
		opts.BucketLookup = minio.BucketLookupPath
	}
	return minio.New(u.Host, opts)
}

func (s *Storage) PresignUpload(ctx context.Context, key, mime string, size int64) (string, map[string]string, error) {
	headers := map[string]string{"Content-Type": mime, "Content-Length": strconv.FormatInt(size, 10)}
	signed := make(http.Header, len(headers))
	for name, value := range headers {
		signed.Set(name, value)
	}
	u, err := s.presigner.PresignHeader(ctx, http.MethodPut, s.bucket, key, uploadLifetime, nil, signed)
	if err != nil {
		return "", nil, err
	}
	return u.String(), headers, nil
}

func (s *Storage) OpenUpload(ctx context.Context, key string) (io.ReadCloser, error) {
	response, err := s.objects.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, err
	}
	// The SDK opens objects lazily. Surface a missing upload before decoding.
	if _, err = response.Stat(); err != nil {
		_ = response.Close()
		if minio.ToErrorResponse(err).StatusCode == http.StatusNotFound {
			return nil, fmt.Errorf("%w: %v", ErrUploadMissing, err)
		}
		return nil, err
	}
	return response, nil
}

func (s *Storage) Publish(ctx context.Context, key, mime string, data []byte) error {
	_, err := s.objects.PutObject(ctx, s.bucket, key, bytes.NewReader(data), int64(len(data)), minio.PutObjectOptions{
		ContentType: mime, DisableMultipart: true,
		CacheControl: "public, max-age=31536000, immutable",
	})
	return err
}

func (s *Storage) Delete(ctx context.Context, key string) error {
	return s.objects.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{})
}

func (s *Storage) ImageURL(key string, width int) string {
	source := base64.RawURLEncoding.EncodeToString([]byte("s3://" + s.bucket + "/" + key))
	path := fmt.Sprintf("/rs:fit:%d:0:0/%s", width, source)
	mac := hmac.New(sha256.New, s.imageKey)
	_, _ = mac.Write(s.imageSalt)
	_, _ = mac.Write([]byte(path))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return s.imageBase + "/" + signature + path
}
