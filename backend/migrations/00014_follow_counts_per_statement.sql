-- +goose Up

-- Счётчики подписок — один раз на запрос, а не на строку. Строчный триггер
-- из 00012 при удалении аккаунта с 100k подписчиков 100k раз переписывал
-- одну и ту же строку users в одной транзакции: каждая новая версия строки
-- искалась дольше предыдущей, удаление шло 3,5 минуты (замер на 1,2M
-- подписок) и обрывалось таймаутом запроса. Триггер на запрос видит все
-- строки разом (transition table) и меняет каждый счётчик одним UPDATE:
-- то же удаление — 2 с. Одиночная подписка — по-прежнему одна строка.
--
-- Счётчик постов (posts_author_count) остаётся строчным: посты удаляются
-- по одному, а триггер на запрос для UPDATE нельзя ограничить колонками —
-- он срабатывал бы на каждый сброс голосов воркером. Массовое удаление
-- постов (модерация) должно будет пересчитать posts_count само.
DROP TRIGGER user_follows_count ON user_follows;
DROP FUNCTION user_follows_count();

-- +goose StatementBegin
CREATE FUNCTION user_follows_count() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    step integer := CASE TG_OP WHEN 'INSERT' THEN 1 ELSE -1 END;
BEGIN
    UPDATE users u SET following_count = following_count + step * d.n
    FROM (SELECT follower_id AS id, count(*) AS n FROM changed GROUP BY 1) d
    WHERE u.id = d.id;
    UPDATE users u SET followers_count = followers_count + step * d.n
    FROM (SELECT followee_id AS id, count(*) AS n FROM changed GROUP BY 1) d
    WHERE u.id = d.id;
    RETURN NULL;
END $$;
-- +goose StatementEnd

CREATE TRIGGER user_follows_count_insert AFTER INSERT ON user_follows
    REFERENCING NEW TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION user_follows_count();
CREATE TRIGGER user_follows_count_delete AFTER DELETE ON user_follows
    REFERENCING OLD TABLE AS changed FOR EACH STATEMENT EXECUTE FUNCTION user_follows_count();

-- +goose Down

DROP TRIGGER user_follows_count_insert ON user_follows;
DROP TRIGGER user_follows_count_delete ON user_follows;
DROP FUNCTION user_follows_count();

-- +goose StatementBegin
CREATE FUNCTION user_follows_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE users SET following_count = following_count + 1 WHERE id = NEW.follower_id;
        UPDATE users SET followers_count = followers_count + 1 WHERE id = NEW.followee_id;
    ELSE
        UPDATE users SET following_count = following_count - 1 WHERE id = OLD.follower_id;
        UPDATE users SET followers_count = followers_count - 1 WHERE id = OLD.followee_id;
    END IF;
    RETURN NULL;
END $$;
-- +goose StatementEnd

CREATE TRIGGER user_follows_count AFTER INSERT OR DELETE ON user_follows
    FOR EACH ROW EXECUTE FUNCTION user_follows_count();
