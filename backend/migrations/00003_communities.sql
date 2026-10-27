-- +goose Up

-- Подписка и модерация — разные вещи: модератор может отписаться от ленты
-- сообщества и остаться модератором. Поэтому роли уезжают в отдельную таблицу,
-- а строка в community_members означает только «подписан».
CREATE TYPE moderator_role AS ENUM ('moderator', 'owner');

CREATE TABLE community_moderators (
    community_id bigint         NOT NULL REFERENCES communities (id) ON DELETE CASCADE,
    user_id      bigint         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role         moderator_role NOT NULL,
    created_at   timestamptz    NOT NULL DEFAULT now(),
    PRIMARY KEY (community_id, user_id)
);
CREATE INDEX community_moderators_user_idx ON community_moderators (user_id);
CREATE UNIQUE INDEX community_moderators_one_owner_idx ON community_moderators (community_id) WHERE role = 'owner';

INSERT INTO community_moderators (community_id, user_id, role, created_at)
SELECT community_id, user_id, role::text::moderator_role, created_at
FROM community_members WHERE role <> 'member';

ALTER TABLE community_members DROP COLUMN role; -- вместе с ним уходит индекс (community_id, role)
DROP TYPE community_role;
CREATE INDEX community_members_community_idx ON community_members (community_id);

-- Подписки на порядки реже голосов: счётчик ведёт синхронный триггер.
-- +goose StatementBegin
CREATE FUNCTION community_members_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE communities SET subscribers_count = subscribers_count + 1 WHERE id = NEW.community_id;
    ELSE
        UPDATE communities SET subscribers_count = subscribers_count - 1 WHERE id = OLD.community_id;
    END IF;
    RETURN NULL;
END $$;
-- +goose StatementEnd

CREATE TRIGGER community_members_count AFTER INSERT OR DELETE ON community_members
    FOR EACH ROW EXECUTE FUNCTION community_members_count();

UPDATE communities c
SET subscribers_count = (SELECT count(*) FROM community_members m WHERE m.community_id = c.id);

-- Keyset (subscribers_count, id) < (...) при ORDER BY ... DESC, id DESC требует
-- id DESC в индексе; в 00001 он был ASC и для пагинации не годился.
DROP INDEX communities_popular_idx;
CREATE INDEX communities_popular_idx ON communities (subscribers_count DESC, id DESC) WHERE NOT is_nsfw;

-- Лимит «не больше N новых сообществ в сутки» на пользователя.
CREATE INDEX communities_created_by_idx ON communities (created_by, created_at);

-- +goose Down

DROP INDEX communities_created_by_idx;
DROP INDEX communities_popular_idx;
CREATE INDEX communities_popular_idx ON communities (subscribers_count DESC, id);

DROP TRIGGER community_members_count ON community_members;
DROP FUNCTION community_members_count();

DROP INDEX community_members_community_idx;
CREATE TYPE community_role AS ENUM ('member', 'moderator', 'owner');
ALTER TABLE community_members ADD COLUMN role community_role NOT NULL DEFAULT 'member';
UPDATE community_members m SET role = cm.role::text::community_role
FROM community_moderators cm
WHERE cm.community_id = m.community_id AND cm.user_id = m.user_id;
CREATE INDEX community_members_community_idx ON community_members (community_id, role);

DROP TABLE community_moderators;
DROP TYPE moderator_role;
