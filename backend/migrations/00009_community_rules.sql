-- +goose Up

-- Правила сообщества: короткий упорядоченный список «заголовок + пояснение».
-- jsonb, а не отдельная таблица: правила читаются и меняются только целиком
-- (страница сообщества, PATCH модератора), поштучных запросов к ним нет.
-- Формат элемента — {"title": "...", "body": "..."}; длины проверяет сервис.
ALTER TABLE communities
    ADD COLUMN rules jsonb NOT NULL DEFAULT '[]'
        CONSTRAINT communities_rules_check
        CHECK (jsonb_typeof(rules) = 'array' AND jsonb_array_length(rules) <= 15);

-- +goose Down

ALTER TABLE communities DROP COLUMN rules;
