-- +goose Up

-- Подписки на людей. Строка = «follower читает followee». Счётчики в users
-- ведут синхронные триггеры, как у подписок на сообщества: шапка профиля
-- читает одну строку, а не считает COUNT(*) по миллионам подписок.
CREATE TABLE user_follows (
    follower_id bigint      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    followee_id bigint      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followee_id),
    CHECK (follower_id <> followee_id)
);
-- Списки «подписчики» (новые сверху); «подписки» идут по первичному ключу.
CREATE INDEX user_follows_followee_idx ON user_follows (followee_id, created_at DESC);

ALTER TABLE users
    ADD COLUMN posts_count     integer NOT NULL DEFAULT 0,
    ADD COLUMN followers_count integer NOT NULL DEFAULT 0,
    ADD COLUMN following_count integer NOT NULL DEFAULT 0;

-- +goose StatementBegin
CREATE FUNCTION user_follows_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE users SET following_count = following_count + 1 WHERE id = NEW.follower_id;
        UPDATE users SET followers_count = followers_count + 1 WHERE id = NEW.followee_id;
    ELSE
        UPDATE users SET following_count = following_count - 1 WHERE id = OLD.follower_id;
        UPDATE users SET followers_count = followers_count - 1 WHERE id = OLD.followee_id;
    END IF;
    RETURN NULL;
END $$;
-- +goose StatementEnd

CREATE TRIGGER user_follows_count AFTER INSERT OR DELETE ON user_follows
    FOR EACH ROW EXECUTE FUNCTION user_follows_count();

-- Живые посты автора: создание +1, мягкое удаление −1 (и обратно, если
-- когда-нибудь появится восстановление).
-- +goose StatementBegin
CREATE FUNCTION posts_author_count() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    was_live boolean := TG_OP <> 'INSERT' AND OLD.deleted_at IS NULL AND OLD.author_id IS NOT NULL;
    is_live  boolean := TG_OP <> 'DELETE' AND NEW.deleted_at IS NULL AND NEW.author_id IS NOT NULL;
BEGIN
    IF was_live AND NOT is_live THEN
        UPDATE users SET posts_count = posts_count - 1 WHERE id = OLD.author_id;
    ELSIF is_live AND NOT was_live THEN
        UPDATE users SET posts_count = posts_count + 1 WHERE id = NEW.author_id;
    END IF;
    RETURN NULL;
END $$;
-- +goose StatementEnd

CREATE TRIGGER posts_author_count AFTER INSERT OR DELETE OR UPDATE OF deleted_at, author_id ON posts
    FOR EACH ROW EXECUTE FUNCTION posts_author_count();

UPDATE users u SET posts_count = (
    SELECT count(*) FROM posts p WHERE p.author_id = u.id AND p.deleted_at IS NULL);

-- +goose Down

DROP TRIGGER posts_author_count ON posts;
DROP FUNCTION posts_author_count();
DROP TRIGGER user_follows_count ON user_follows;
DROP FUNCTION user_follows_count();
ALTER TABLE users
    DROP COLUMN posts_count,
    DROP COLUMN followers_count,
    DROP COLUMN following_count;
DROP TABLE user_follows;
