-- +goose Up

ALTER TABLE media
    ADD COLUMN upload_key text,
    ADD COLUMN content_digest bytea,
    ADD COLUMN publish_started_at timestamptz;

CREATE INDEX media_staging_idx ON media (created_at, id) WHERE upload_key IS NOT NULL;
CREATE INDEX users_avatar_key_idx ON users (avatar_key) WHERE avatar_key IS NOT NULL;
CREATE INDEX communities_icon_key_idx ON communities (icon_key) WHERE icon_key IS NOT NULL;
CREATE INDEX communities_banner_key_idx ON communities (banner_key) WHERE banner_key IS NOT NULL;

-- +goose Down

DROP INDEX communities_banner_key_idx;
DROP INDEX communities_icon_key_idx;
DROP INDEX users_avatar_key_idx;
DROP INDEX media_staging_idx;

ALTER TABLE media DROP COLUMN publish_started_at, DROP COLUMN content_digest, DROP COLUMN upload_key;
