-- +goose Up

-- Вход по нику и паролю. Отдельная таблица, а не колонка в users: у
-- большинства аккаунтов (Apple, Telegram) пароля нет, а хеш не должен
-- случайно уехать в выборку профиля.
CREATE TABLE password_credentials (
    user_id    bigint      PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    hash       text        NOT NULL, -- argon2id в формате PHC: $argon2id$v=19$m=...,t=...,p=...$salt$hash
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- +goose Down

DROP TABLE password_credentials;
