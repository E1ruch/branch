-- +goose Up

-- Список «подписки» человека, новые сверху: (follower_id, created_at DESC)
-- читается по индексу и останавливается на странице. Первичный ключ
-- (follower_id, followee_id) упорядочен не по времени.
CREATE INDEX user_follows_follower_idx ON user_follows (follower_id, created_at DESC);

-- +goose Down

DROP INDEX user_follows_follower_idx;
