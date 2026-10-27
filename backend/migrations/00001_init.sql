-- +goose Up

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- «Горячее». Зеркало ranking.Hot в Go: Go пишет hot_rank при каждом
-- изменении голосов, SQL-версия нужна для DEFAULT и бэкфилла при смене констант:
--   UPDATE posts SET hot_rank = hot_rank(upvotes, downvotes, created_at);
-- 1767225600 = 2026-01-01T00:00:00Z, 45000 с = 12.5 ч на порядок голосов.
-- +goose StatementBegin
CREATE FUNCTION hot_rank(ups integer, downs integer, created timestamptz)
RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT sign((ups - downs)::float8) * log(1 + abs(ups - downs)::float8)
         + (extract(epoch FROM created)::float8 - 1767225600) / 45000
$$;
-- +goose StatementEnd

-- ============================================================
-- Пользователи и авторизация
-- ============================================================

CREATE TABLE users (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Только латиница: защита от гомоглифов (а/a). Кириллица — в display_name.
    username      citext      NOT NULL UNIQUE CHECK (username ~ '^[A-Za-z0-9_]{3,24}$'),
    display_name  text        CHECK (char_length(display_name) <= 48),
    avatar_key    text,
    bio           text        CHECK (char_length(bio) <= 300),
    -- Денормализованы, обновляются воркером пачками из Redis.
    post_karma    integer     NOT NULL DEFAULT 0,
    comment_karma integer     NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);
CREATE INDEX users_username_trgm_idx ON users USING gin ((username::text) gin_trgm_ops);

CREATE TYPE auth_provider AS ENUM ('apple', 'telegram');

CREATE TABLE auth_identities (
    provider   auth_provider NOT NULL,
    subject    text          NOT NULL, -- Apple `sub` / Telegram user id
    user_id    bigint        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, subject)
);
CREATE INDEX auth_identities_user_idx ON auth_identities (user_id);

CREATE TABLE refresh_tokens (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     bigint      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash  bytea       NOT NULL UNIQUE, -- sha256; сам токен не храним
    -- Ротация: повторное использование уже обменянного токена отзывает всю семью.
    family_id   uuid        NOT NULL,
    device_name text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz
);
CREATE INDEX refresh_tokens_user_idx ON refresh_tokens (user_id) WHERE revoked_at IS NULL;
CREATE INDEX refresh_tokens_family_idx ON refresh_tokens (family_id);

-- ============================================================
-- Сообщества
-- ============================================================

CREATE TABLE communities (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug              citext      NOT NULL UNIQUE CHECK (slug ~ '^[A-Za-z0-9_]{3,32}$'),
    title             text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 64),
    description       text        NOT NULL DEFAULT '' CHECK (char_length(description) <= 1000),
    icon_key          text,
    banner_key        text,
    is_nsfw           boolean     NOT NULL DEFAULT false,
    subscribers_count integer     NOT NULL DEFAULT 0,
    created_by        bigint      REFERENCES users (id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX communities_popular_idx ON communities (subscribers_count DESC, id);
CREATE INDEX communities_search_trgm_idx ON communities USING gin ((slug::text || ' ' || title) gin_trgm_ops);

CREATE TYPE community_role AS ENUM ('member', 'moderator', 'owner');

CREATE TABLE community_members (
    user_id      bigint         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    community_id bigint         NOT NULL REFERENCES communities (id) ON DELETE CASCADE,
    role         community_role NOT NULL DEFAULT 'member',
    created_at   timestamptz    NOT NULL DEFAULT now(),
    -- user_id первым: «мои подписки» для ленты подписок — самый частый запрос.
    PRIMARY KEY (user_id, community_id)
);
CREATE INDEX community_members_community_idx ON community_members (community_id, role);

-- ============================================================
-- Посты и медиа
-- ============================================================

CREATE TABLE posts (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    community_id  bigint      NOT NULL REFERENCES communities (id),
    author_id     bigint      REFERENCES users (id) ON DELETE SET NULL,
    title         text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 300),
    body          text        NOT NULL DEFAULT '' CHECK (char_length(body) <= 40000),
    is_nsfw       boolean     NOT NULL DEFAULT false,
    upvotes       integer     NOT NULL DEFAULT 0,
    downvotes     integer     NOT NULL DEFAULT 0,
    score         integer     GENERATED ALWAYS AS (upvotes - downvotes) STORED,
    comment_count integer     NOT NULL DEFAULT 0,
    hot_rank      double precision NOT NULL DEFAULT hot_rank(0, 0, now()),
    created_at    timestamptz NOT NULL DEFAULT now(),
    edited_at     timestamptz,
    deleted_at    timestamptz
);
-- Keyset-пагинация: (hot_rank, id) < ($cursor_rank, $cursor_id).
-- «Новое» сортируем по id: identity монотонен, индекс меньше, курсор — одно число.
CREATE INDEX posts_hot_idx           ON posts (hot_rank DESC, id DESC)               WHERE deleted_at IS NULL;
CREATE INDEX posts_new_idx           ON posts (id DESC)                              WHERE deleted_at IS NULL;
CREATE INDEX posts_community_hot_idx ON posts (community_id, hot_rank DESC, id DESC) WHERE deleted_at IS NULL;
CREATE INDEX posts_community_new_idx ON posts (community_id, id DESC)                WHERE deleted_at IS NULL;
CREATE INDEX posts_author_idx        ON posts (author_id, id DESC)                   WHERE deleted_at IS NULL;
CREATE INDEX posts_title_trgm_idx    ON posts USING gin (title gin_trgm_ops)         WHERE deleted_at IS NULL;

CREATE TYPE media_kind   AS ENUM ('image', 'video');
CREATE TYPE media_status AS ENUM ('pending', 'ready', 'failed');

-- Медиа грузится до поста (presigned URL), потом привязывается к посту.
CREATE TABLE media (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id    bigint       NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    post_id     bigint       REFERENCES posts (id) ON DELETE CASCADE,
    position    smallint     NOT NULL DEFAULT 0,
    kind        media_kind   NOT NULL,
    status      media_status NOT NULL DEFAULT 'pending',
    storage_key text         NOT NULL UNIQUE,
    mime_type   text         NOT NULL,
    size_bytes  bigint,
    -- Размеры обязательны для ready: клиент верстает ячейку до загрузки, без прыжков.
    width       integer      CHECK (width > 0),
    height      integer      CHECK (height > 0),
    duration_ms integer      CHECK (duration_ms > 0),
    thumbhash   bytea,       -- ~25 байт, плейсхолдер рисуется мгновенно
    created_at  timestamptz  NOT NULL DEFAULT now(),
    CHECK (status <> 'ready' OR (width IS NOT NULL AND height IS NOT NULL))
);
CREATE UNIQUE INDEX media_post_position_idx ON media (post_id, position) WHERE post_id IS NOT NULL;
CREATE INDEX media_orphans_idx ON media (created_at) WHERE post_id IS NULL; -- GC неприкреплённых

-- ============================================================
-- Голоса
-- ============================================================
-- Строка = текущий голос; снятие голоса = DELETE. Клиент шлёт желаемое
-- состояние (-1/0/1), а не toggle — запрос идемпотентен, ретраи безопасны.
-- Счётчики в posts/comments/users обновляет воркер пачками (через Redis),
-- чтобы горячий пост не упирался в блокировку одной строки.

CREATE TABLE post_votes (
    user_id    bigint      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    post_id    bigint      NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    value      smallint    NOT NULL CHECK (value IN (-1, 1)),
    created_at timestamptz NOT NULL DEFAULT now(),
    -- user_id первым: «мои голоса для этих 25 постов» — на каждую страницу ленты.
    PRIMARY KEY (user_id, post_id)
);
CREATE INDEX post_votes_post_idx ON post_votes (post_id); -- сверка счётчиков, каскад

-- ============================================================
-- Комментарии
-- ============================================================
-- Список смежности + root_id + depth. Типовые запросы:
--   1) маленький тред целиком:          post_id = $1                     (comments_post_idx)
--   2) страница верхнего уровня:        post_id = $1 AND parent_id IS NULL (comments_top_idx)
--   3) поддеревья этой страницы разом:  root_id = ANY($roots) AND depth <= $n (comments_root_idx)
--   4) «ещё N ответов»:                 parent_id = $1                    (comments_parent_idx)
-- Дерево собирает Go и отдаёт клиенту плоским списком с depth.

CREATE TABLE comments (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    post_id     bigint      NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    parent_id   bigint      REFERENCES comments (id) ON DELETE CASCADE,
    root_id     bigint      NOT NULL REFERENCES comments (id) ON DELETE CASCADE,
    depth       smallint    NOT NULL,
    author_id   bigint      REFERENCES users (id) ON DELETE SET NULL,
    body        text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 10000),
    upvotes     integer     NOT NULL DEFAULT 0,
    downvotes   integer     NOT NULL DEFAULT 0,
    score       integer     GENERATED ALWAYS AS (upvotes - downvotes) STORED,
    reply_count integer     NOT NULL DEFAULT 0, -- прямые ответы, для «ещё N ответов»
    created_at  timestamptz NOT NULL DEFAULT now(),
    edited_at   timestamptz,
    deleted_at  timestamptz -- мягкое удаление: ветка сохраняется, тело скрывает API
);
CREATE INDEX comments_post_idx   ON comments (post_id, id);
CREATE INDEX comments_top_idx    ON comments (post_id, score DESC, id) WHERE parent_id IS NULL;
CREATE INDEX comments_root_idx   ON comments (root_id, depth, score DESC, id);
CREATE INDEX comments_parent_idx ON comments (parent_id, score DESC, id) WHERE parent_id IS NOT NULL;
CREATE INDEX comments_author_idx ON comments (author_id, id DESC) WHERE deleted_at IS NULL;

-- root_id/depth вычисляем в БД: клиент не может прислать неконсистентное дерево.
-- +goose StatementBegin
CREATE FUNCTION comments_set_tree() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    p comments%ROWTYPE;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.root_id := NEW.id;
        NEW.depth   := 0;
    ELSE
        SELECT * INTO p FROM comments WHERE id = NEW.parent_id;
        IF NOT FOUND OR p.post_id <> NEW.post_id THEN
            RAISE EXCEPTION 'parent comment % does not belong to post %', NEW.parent_id, NEW.post_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        NEW.root_id := p.root_id;
        NEW.depth   := p.depth + 1;
    END IF;
    RETURN NEW;
END $$;
-- +goose StatementEnd

-- Комментарии на порядки реже голосов, поэтому их счётчики — синхронным триггером.
-- +goose StatementBegin
CREATE FUNCTION comments_bump_counters() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE posts SET comment_count = comment_count + 1 WHERE id = NEW.post_id;
    IF NEW.parent_id IS NOT NULL THEN
        UPDATE comments SET reply_count = reply_count + 1 WHERE id = NEW.parent_id;
    END IF;
    RETURN NULL;
END $$;
-- +goose StatementEnd

CREATE TRIGGER comments_set_tree BEFORE INSERT ON comments
    FOR EACH ROW EXECUTE FUNCTION comments_set_tree();
CREATE TRIGGER comments_bump_counters AFTER INSERT ON comments
    FOR EACH ROW EXECUTE FUNCTION comments_bump_counters();

CREATE TABLE comment_votes (
    user_id    bigint      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    comment_id bigint      NOT NULL REFERENCES comments (id) ON DELETE CASCADE,
    value      smallint    NOT NULL CHECK (value IN (-1, 1)),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, comment_id)
);
CREATE INDEX comment_votes_comment_idx ON comment_votes (comment_id);

-- +goose Down

DROP TABLE comment_votes;
DROP TABLE comments;
DROP FUNCTION comments_bump_counters();
DROP FUNCTION comments_set_tree();
DROP TABLE post_votes;
DROP TABLE media;
DROP TYPE media_status;
DROP TYPE media_kind;
DROP TABLE posts;
DROP TABLE community_members;
DROP TYPE community_role;
DROP TABLE communities;
DROP TABLE refresh_tokens;
DROP TABLE auth_identities;
DROP TYPE auth_provider;
DROP TABLE users;
DROP FUNCTION hot_rank(integer, integer, timestamptz);
