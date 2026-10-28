-- +goose Up

-- Истории: посты одного автора, связанные в части («Часть 1», «Часть 2»…).
-- Отдельная таблица, а не ссылка «продолжение поста X»: номер части и
-- оглавление — один индексный проход, а не обход цепочки.
--
-- story_part только растёт и не пересчитывается при удалении части:
-- читателю номер считается по живым частям (row_number), а уникальный
-- индекс защищает порядок от гонки двух публикаций разом.
CREATE TABLE stories (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    author_id  bigint      REFERENCES users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE posts
    ADD COLUMN story_id   bigint  REFERENCES stories (id),
    ADD COLUMN story_part integer,
    ADD CONSTRAINT posts_story_part_check CHECK ((story_id IS NULL) = (story_part IS NULL));

CREATE UNIQUE INDEX posts_story_part_idx ON posts (story_id, story_part) WHERE story_id IS NOT NULL;

-- +goose Down

DROP INDEX posts_story_part_idx;
ALTER TABLE posts DROP CONSTRAINT posts_story_part_check, DROP COLUMN story_part, DROP COLUMN story_id;
DROP TABLE stories;
