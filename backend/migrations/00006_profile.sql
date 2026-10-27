-- +goose Up

-- Первая смена ника бесплатна (это выбор ника при онбординге вместо
-- выданного user_xxxxxxxx), дальше — не чаще раза в 30 дней. NULL = ещё не меняли.
ALTER TABLE users ADD COLUMN username_changed_at timestamptz;

-- +goose Down

ALTER TABLE users DROP COLUMN username_changed_at;
