-- +goose Up

-- «Популярные запросы» на экране поиска. Строка — «этот пользователь в этот
-- день искал это»: один человек, повторяющий запрос, считается один раз в
-- день, и накрутить тренд в одиночку нельзя. Анонимные поиски не пишутся.
-- Строки старше недели не нужны — их удаляет воркер (search.Prune).
CREATE TABLE search_query_hits (
    day     date   NOT NULL,
    query   text   NOT NULL CHECK (char_length(query) BETWEEN 2 AND 64),
    user_id bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    PRIMARY KEY (day, query, user_id)
);

-- Люди ищут и по имени, не только по нику (индекс по нику есть с 00001).
CREATE INDEX users_display_name_trgm_idx ON users USING gin (display_name gin_trgm_ops)
    WHERE deleted_at IS NULL;

-- +goose Down

DROP INDEX users_display_name_trgm_idx;
DROP TABLE search_query_hits;
