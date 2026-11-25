-- +goose Up

-- NULL username means the account has not chosen a public nickname yet.
ALTER TABLE users ALTER COLUMN username DROP NOT NULL;
ALTER TABLE password_credentials ADD COLUMN email text UNIQUE;

-- +goose Down

-- Refuse to roll back while accounts are still choosing a nickname.
ALTER TABLE users ALTER COLUMN username SET NOT NULL;
ALTER TABLE password_credentials DROP COLUMN email;
