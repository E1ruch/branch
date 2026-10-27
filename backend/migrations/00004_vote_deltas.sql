-- +goose Up

-- Outbox счётчиков голосов. Голос пишет строку в post_votes и дельту сюда в
-- одной транзакции; воркер раз в секунду забирает дельты пачкой, суммирует и
-- применяет к posts/comments/users одним UPDATE на строку.
--
-- Почему не сразу UPDATE posts: популярный пост получает сотни голосов в
-- минуту, и все они встали бы в очередь на блокировку одной строки.
-- Почему не дельты в Redis (как планировалось): запись в Postgres и Redis не
-- атомарна, при сбое между ними счётчик тихо расходится с голосами. Здесь
-- голос и дельта коммитятся вместе или не коммитятся вовсе.
CREATE TYPE vote_target AS ENUM ('post', 'comment');

CREATE TABLE vote_deltas (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target     vote_target NOT NULL,
    target_id  bigint      NOT NULL,
    author_id  bigint,     -- получает карму; NULL для голоса за себя и удалённых авторов
    up         smallint    NOT NULL,
    down       smallint    NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
)
-- Таблица всё время почти пустая, но через неё течёт каждый голос:
-- чистим мёртвые строки по абсолютному порогу, а не по доле от размера.
WITH (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 1000);

-- Ответ на голос показывает счёт с учётом ещё не применённых дельт.
CREATE INDEX vote_deltas_target_idx ON vote_deltas (target, target_id);

-- +goose Down

DROP TABLE vote_deltas;
DROP TYPE vote_target;
