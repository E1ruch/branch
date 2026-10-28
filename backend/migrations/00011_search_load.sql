-- +goose Up

-- Поиск людей под нагрузкой. Сортировка по похожести заставляла Postgres
-- найти и отсортировать все совпадения (≈250 мс на 200 тыс. пользователей).
-- Теперь ник ищется по началу и отдаётся в порядке этого индекса (доли
-- миллисекунды при любом числе совпадений), имя — по подстроке через
-- trigram из 00010.
CREATE INDEX users_username_prefix_idx ON users (lower(username::text) text_pattern_ops)
    WHERE deleted_at IS NULL;
-- Ник по подстроке больше не ищется, а индекс стоит каждой записи в users.
DROP INDEX users_username_trgm_idx;

-- Готовый список «Популярных запросов». Подсчёт по неделе поисков стоит
-- секунды (3,6 с на 2 млн строк), поэтому его делает воркер раз в несколько
-- минут, а экран поиска читает десяток строк отсюда.
CREATE TABLE search_popular (
    position smallint PRIMARY KEY,
    query    text NOT NULL
);

-- +goose Down

DROP TABLE search_popular;
CREATE INDEX users_username_trgm_idx ON users USING gin ((username::text) gin_trgm_ops);
DROP INDEX users_username_prefix_idx;
