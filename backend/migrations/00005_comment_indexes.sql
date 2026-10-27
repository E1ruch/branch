-- +goose Up

-- Дерево грузится рекурсивным CTE «топ-K ответов каждого родителя» по
-- parent_id, а не поддеревьями по root_id: так у каждого узла гарантированно
-- его лучшие ответы, и «ещё N ответов» продолжает ровно с последнего
-- показанного. root_id остаётся в таблице (ссылка «вся ветка»), но индекс
-- по нему ничего не обслуживает и только удорожает вставку.
DROP INDEX comments_root_idx;

-- Сортировка «новые»: верхний уровень поста и ответы на комментарий.
CREATE INDEX comments_top_new_idx    ON comments (post_id, id DESC)   WHERE parent_id IS NULL;
CREATE INDEX comments_parent_new_idx ON comments (parent_id, id DESC) WHERE parent_id IS NOT NULL;

-- +goose Down

DROP INDEX comments_parent_new_idx;
DROP INDEX comments_top_new_idx;
CREATE INDEX comments_root_idx ON comments (root_id, depth, score DESC, id);
