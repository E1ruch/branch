# Ветка — архитектура

## 1. Монорепозиторий

```
.
├── ios/
│   ├── branch.xcodeproj         тонкий app-target: composition root, табы, роутеры
│   ├── branch/
│   └── Packages/VetkaKit/       SPM-пакет, все модули — его таргеты (см. §4)
├── backend/                     один Go-модуль `vetka`
│   ├── cmd/api/                 HTTP + WebSocket
│   ├── cmd/worker/              счётчики, hot_rank, медиа, GC
│   ├── internal/
│   │   ├── httpapi/             chi-роутер, middleware, хендлеры
│   │   ├── auth/ user/ community/ post/ comment/ vote/ feed/ media/ realtime/
│   │   ├── ranking/             «горячее»
│   │   └── platform/            postgres (pgx), redis, s3
│   ├── queries/                 SQL для sqlc
│   ├── migrations/              goose
│   └── api/openapi.yaml         контракт API, из него же — DTO для iOS
├── infra/
│   └── docker-compose.yml       postgres, redis (+ S3 и imgproxy с модулем медиа)
└── docs/
```

**chi, а не fiber**: chi — это `net/http`, совместимый со всей экосистемой
(middleware, `coder/websocket`, HTTP/2, `httptest`). Fiber на fasthttp ломает эту
совместимость, а выигрыш в скорости для нас незаметен на фоне БД.
Доступ к БД — **pgx + sqlc** (типобезопасный SQL без ORM), миграции — **goose**.

## 2. Схема БД

Миграция: [`backend/migrations/00001_init.sql`](../backend/migrations/00001_init.sql).

- **`bigint identity` вместо UUID**: индексы меньше, «новое» сортируется по `id`,
  курсор пагинации — одно число.
- **Keyset-пагинация** везде: `(hot_rank, id) < ($rank, $id)`, никаких `OFFSET`.
  Под каждую ленту — свой частичный индекс `WHERE deleted_at IS NULL`; «горячее»
  читается Index Only Scan.
- **Голоса**: строка = текущий голос, снятие = `DELETE`. PK `(user_id, post_id)` —
  под запрос «мои голоса для этих 25 постов». Клиент шлёт желаемое состояние
  (`-1/0/1`), а не toggle, поэтому запрос идемпотентен.
- **Счётчики голосов не в триггерах.** Голос → `upsert` в `post_votes` + `HINCRBY`
  дельты в Redis → воркер раз в 1–2 с сбрасывает дельты пачкой в `posts`
  (`upvotes`, `downvotes`, `hot_rank`), карму в `users` и ZSET-ы ленты в Redis.
  Иначе горячий пост упирается в блокировку одной строки.
  Счётчики комментариев — синхронным триггером: комментариев на порядки меньше.
- **Комментарии**: список смежности + `root_id` + `depth` (вычисляются триггером).
  Маленький тред читается одним запросом по `post_id`; большой — страница
  верхнего уровня, а затем все её поддеревья одним запросом
  `root_id = ANY($roots) AND depth <= N`. Дерево собирает Go и отдаёт
  плоским списком с `depth`, который клиент рисует без рекурсии.
  ltree не используем: сортировка его путей лексикографическая (`"100" < "99"`).
- **Медиа** с `width/height/thumbhash` обязательно: ячейка верстается до загрузки
  картинки, без прыжков. Варианты размеров не храним — их отдаёт imgproxy.
- **Поиск**: `pg_trgm` GIN по заголовкам, сообществам и никам (кириллица и
  регистр проверены). Когда перерастём — Meilisearch.

## 3. «Горячее»

```
hot = sign(s) · log10(1 + |s|) + (created_at − 2026-01-01) / 45000,   s = ups − downs
```

[`backend/internal/ranking/hot.go`](../backend/internal/ranking/hot.go) + та же
формула в SQL-функции `hot_rank()`.

- **Логарифм**: первые 10 голосов весят столько же, сколько следующие 90.
  Рано залетевший пост поднимается быстро, вирусный не висит вечно.
- **Время растёт, а не затухает**: свежесть входит как линейно растущая база, так
  что ранг меняется **только при голосовании**. Не нужен пересчёт по крону,
  индекс `(hot_rank, id)` стабилен. 45000 с = 12.5 ч: посту, который на 12.5 ч
  старше, нужно в 10 раз больше голосов.
- `1 + |s|` вместо Reddit-овского `max(|s|, 1)` — первый лайк тоже поднимает ранг.
- Отрицательный счёт топит пост симметрично.

Сдвиг ранга во время скролла лечится **снимком**: первая страница фиксирует
топ-500 id в Redis (`feedsnap:{uuid}`, TTL 30 мин), курсор = снимок + смещение;
глубже — обычный keyset. Клиент дополнительно дедуплицирует по `id`.
Лента подписок — `ZUNIONSTORE` ZSET-ов сообществ (`hot:c:{id}`) во временный ключ
или `LATERAL`-запрос по `posts_community_hot_idx` на каждое сообщество.

Позже: нормализация по размеру сообщества для глобального «горячего» (чтобы
большие сообщества не забивали ленту), вес комментариев («обсуждаемое»).

## 4. iOS

### Модули (таргеты `VetkaKit`)

```
Features ──▶ Stores, DesignSystem, Media ──▶ Networking, Storage ──▶ Core
```

| Модуль | Что внутри |
|---|---|
| `Core` | модели, `Route`, логирование, утилиты |
| `Networking` | `APIClient` (async/await), `Endpoint`, refresh токена single-flight в actor, курсоры, `RealtimeClient` (WebSocket → `AsyncStream<Event>`) |
| `Storage` | GRDB (SQLite): нормализованный кэш постов/сообществ/юзеров и последних страниц лент; Keychain для токенов |
| `Media` | `ImagePipeline`, пул `AVPlayer` |
| `DesignSystem` | токены (цвета, шрифты, отступы), springs, `Haptics`, skeleton/shimmer, декодер ThumbHash |
| `Stores` | `PostStore` / `CommunityStore` — identity map; `VoteService` |
| `Feature*` | `Auth`, `Feed`, `Post`, `Comments`, `Community`, `Profile`, `Search`, `Compose` |

Фичи не зависят друг от друга: переходы только через `Route`. SPM-модули дают
быструю инкрементальную сборку и честные границы (`internal` по умолчанию).

### UIKit vs SwiftUI

- **Лента и комментарии — `UICollectionView`** (compositional layout + diffable
  data source + prefetching) с **чистыми UIKit-ячейками**. `LazyVStack`/`List`
  не дают контроля над reuse, prefetch и высотами, а `UIHostingConfiguration` на
  ячейку — лишняя работа layout'а на кадр. Высоты считаются заранее из данных
  (`width/height` медиа, размеры текста) вне main thread и кэшируются по `id + ширина`.
- Остальные экраны — SwiftUI, лента встраивается через `UIViewControllerRepresentable`.

### Навигация

`TabView` + `NavigationStack(path:)` на каждую вкладку; путь `[Route]` лежит в
`@Observable Router`. Deep links (`vetka://`, universal links) превращаются в
`Route`. Нативный navigation bar (кастомизируется через appearance) — так
interactive back-swipe никогда не ломается. Compose и авторизация — sheet,
просмотр медиа — кастомный UIKit-transition с zoom и swipe-down-to-dismiss.

### Сеть и потоки

- Swift 6 strict concurrency. `@MainActor` — только UI и stores. JSON-декодинг,
  парсинг markdown в `AttributedString`, расчёт высот — вне main thread.
- Access JWT (15 мин) + refresh с ротацией. Параллельные 401 ждут **один**
  refresh в actor.
- WebSocket: подписка на темы (`post:{id}` для открытого поста, счётчики видимых
  постов); события вливаются в stores, сервер шлёт их пачками раз в 1–2 с.

### Кэш и плавность

- **Изображения**: imgproxy отдаёт ширину из фиксированного набора (320/640/1080/1440)
  → меньше трафика и высокий cache hit. На клиенте: даунсэмплинг через ImageIO
  (`CGImageSourceCreateThumbnailAtIndex`) и предекодирование в фоне, `NSCache`
  готовых битмапов по `url + pixelSize`, сырые байты — в дисковом кэше,
  склейка одинаковых запросов, приоритеты и отмена. Пока картинка грузится,
  показывается ThumbHash.
- **Предзагрузка**: следующая страница — за ~10 ячеек до конца, картинки —
  на N ячеек вперёд, с отменой при уходе с экрана.
- **Холодный старт**: лента сразу из GRDB, затем фоновое обновление и применение
  diff (stale-while-revalidate). Skeleton только при пустом кэше.
- **Оптимистичный UI**: `VoteService` мгновенно меняет `PostStore` + haptic,
  частые тапы склеиваются (300 мс) и отправляется только итоговое состояние;
  при ошибке — откат с анимацией. Store один, поэтому лайк в деталях поста
  сразу виден и в ленте.
- **Видео**: в ленте — muted autoplay только для самой видимой ячейки, пул из 2–3
  `AVPlayer` вместо плеера на ячейку.

### Авторизация

- **Sign in with Apple**: `identityToken` → бэкенд проверяет его по JWKS Apple.
- **Telegram**: `ASWebAuthenticationSession` открывает нашу страницу с Telegram
  Login Widget, редирект обратно в приложение; бэкенд проверяет HMAC-SHA256
  подпись данных ключом `SHA256(bot_token)`. Нужен бот и привязанный к нему домен.
