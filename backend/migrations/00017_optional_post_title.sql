-- +goose Up
ALTER TABLE posts
    DROP CONSTRAINT posts_title_check,
    ADD CONSTRAINT posts_title_check CHECK (char_length(title) <= 300);

CREATE INDEX posts_untitled_body_trgm_idx ON posts USING gin (body gin_trgm_ops)
    WHERE deleted_at IS NULL AND title = '';

-- +goose Down
DROP INDEX posts_untitled_body_trgm_idx;

ALTER TABLE posts
    DROP CONSTRAINT posts_title_check,
    ADD CONSTRAINT posts_title_check CHECK (char_length(title) BETWEEN 1 AND 300);
