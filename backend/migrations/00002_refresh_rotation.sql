-- +goose Up

-- Ротация отделена от отзыва: rotated_at — токен обменян на новый,
-- revoked_at — выход или обнаружен повтор, вся семья мертва.
-- Повтор обменянного токена в течение короткого окна — это ретрай клиента
-- после потерянного ответа, а не атака, поэтому семью он не убивает.
ALTER TABLE refresh_tokens ADD COLUMN rotated_at timestamptz;

-- +goose Down

ALTER TABLE refresh_tokens DROP COLUMN rotated_at;
