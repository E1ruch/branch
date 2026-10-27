# Ветка — передача контекста в новый чат

Прочитай этот файл целиком, затем `docs/architecture.md` (архитектура и все
ключевые решения) и `docs/design-system.md` (дизайн-система — источник правды
по цветам и UX). Код — главный источник правды; здесь то, чего в коде не видно.

## Проект

«Ветка» — iOS-приложение сообществ для СНГ (гибрид Reddit и Пикабу). Хобби-проект,
но архитектура должна выдерживать рост. Монорепо:

- `backend/` — Go 1.26+ (chi, pgx без ORM, goose), PostgreSQL 16, Redis 7.
  `cmd/api` (HTTP), `cmd/worker` (сбрасывает голоса в счётчики), `cmd/migrate`.
- `ios/` — `branch.xcodeproj` (тонкий app-таргет `VetkaApp.swift`) + локальный
  SPM-пакет `ios/Packages/VetkaKit` (Swift 6, strict concurrency, iOS 17):
  `Core`, `Networking`, `Session`, `DesignSystem`, `AuthFeature`,
  `CommunitiesFeature`, `FeedFeature`, `AppFeature`.
- `infra/docker-compose.yml` — Postgres и Redis.

Приоритеты (не обсуждаются): плавность уровня Telegram (ничего тяжёлого в main,
оптимистичный UI, skeleton вместо спиннеров), жесты и haptics, чистый UI.

## Как работать с пользователем

- Общение по-русски, коротко, объяснять только ключевые решения.
- Модули — по одному; после модуля ждать «дальше» (или выбора следующего шага).
- **Коммитить только когда пользователь просит** («Сделай коммит…»). Перед
  коммитом смотреть `git status`: однажды `git add -A` захватил локальную схему
  Xcode с IP Mac'а — теперь она в `.gitignore`. В конце сообщения коммита строка
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Ничего не пушить.
- Проверять вживую: тесты + запуск (бэкенд — curl/смоук, iOS — симулятор и
  скриншоты). Честно говорить, что не проверено.
- Пользователь тестирует и на своём iPhone. Платной команды Apple нет →
  Sign in with Apple скрыт флагом `AppEnvironment.Features.signInWithApple`,
  entitlement отвязан (как включить — в комментарии у флага).
- Решения пользователя по дизайну: цвета — по `docs/design-system.md`;
  основные кнопки — белый текст на `#119B82` (в тёмной теме `#092B23` на
  `#20C997`); где пара не проходит WCAG, брать ближайший тёмный оттенок того
  же тона (все такие места подписаны в `Palette.swift`).

## Запуск локально

```bash
cd backend
make infra-up      # Postgres + Redis в Docker (Docker пользователь запускает сам)
make migrate       # применено 00001–00007
make run           # API на :8080 (слушает все интерфейсы)
make worker        # обязателен: без него счёт и «горячее» не двигаются
make test          # TEST_DATABASE_URL уже задан в Makefile; каждый тест — своя БД
```

- `backend/.env` — локальный (в `.gitignore`): постоянный `JWT_SIGNING_KEY`
  уже вписан. Telegram выключен; для локального Telegram-входа есть
  `TELEGRAM_FAKE_LOGIN=true` + любые `TELEGRAM_BOT_TOKEN/USERNAME` (см.
  `.env.example`; с https в `PUBLIC_BASE_URL` сервер не стартует).
- Вход в приложение локально — по нику и паролю (регистрация в приложении).
  В базе есть тестовые пользователи `live_test`, `live_voter`, `dev`, `dev2`
  (пароли у `dev*` знает пользователь), ~70 постов и 13 сообществ.
- В прошлом чате API и воркер были запущены во вкладках терминала; в новом
  их нужно поднять заново.

### iOS

- `xcode-select` указывает на Command Line Tools — **каждой** команде
  `xcodebuild`/`xcrun` передавать
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (или попросить пользователя сделать `sudo xcode-select -s …`; без этого не
  работает и панель симулятора Claude).
- Тесты пакета: `cd ios/Packages/VetkaKit && xcodebuild test -scheme VetkaKit
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (42 теста, Swift Testing).
- Приложение и UI-тесты: `cd ios && xcodebuild test -project branch.xcodeproj
  -scheme branch -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
  -parallel-testing-enabled NO -only-testing:branchUITests/branchUITests/…`.
  Скриншоты из UI-тестов: `xcrun xcresulttool export attachments --path X.xcresult --output-path DIR`.
- Тапать в симуляторе через `simctl` нельзя — для проверки UI писать XCUITest
  или снимать `xcrun simctl io <device> screenshot`. Тёмная тема:
  `xcrun simctl ui <device> appearance dark`.
- Телефон: в схеме Xcode `VETKA_API_URL=http://<IP Mac>:8080` (сейчас
  `192.168.31.37`); debug-сборка запоминает адрес; нужно разрешение «Локальная сеть».

## Что сделано (по коммитам)

Бэкенд (всё под `/v1`, ошибки `{"error":{"code","message","field"}}`, курсоры непрозрачные, списки `{items, next_cursor}`):

- Авторизация: ник+пароль (argon2id, лимиты попыток), Apple (JWKS, nonce),
  Telegram (HMAC, анти-replay, фейковый локальный вход); access JWT Ed25519 15 мин
  + refresh с ротацией и детектом кражи (grace 30 с).
- Профиль: `/me` (GET/PATCH/DELETE), `/users/{username}` (+`/posts`, `/comments`),
  проверка ника; первая смена ника бесплатна, дальше раз в 30 дней; удаление аккаунта.
- Сообщества: создание (3 в сутки), правка модераторами, подписка PUT/DELETE,
  популярные, trigram-поиск, мои подписки. NSFW скрыт из дискавери.
- Посты и ленты: hot/new общая, по сообществу, подписки (LATERAL); превью 600 символов.
- Голоса: PUT состояния (−1/0/1), outbox `vote_deltas` + воркер, карма.
- Комментарии: дерево (топ-8 ответов на родителя, 5 уровней, лимит 400),
  заглушки `more`/`continue`, надгробия, голоса за комментарии.

iOS:

- Сеть (`Endpoint<Response>`, `APIClient`, каталог `API`), сессия (Keychain,
  актор `TokenStore` с единым refresh), роутер с отдельным стеком на вкладку и deep links.
- Вход/регистрация по паролю, онбординг с живой проверкой ника.
- Лента на `UICollectionView` (PostLayout считается вне main, ячейки без
  Auto Layout), три ленты в контейнере, оптимистичные голоса с дебаунсом 300 мс,
  свайпы вправо/влево = за/против, контекстное меню, «⋯», поделиться.
- Редизайн шаг 1: токены `Palette`, 5 вкладок (Лента, Поиск, «+», Активность,
  Профиль), шапка ленты с логотипом и «пилюлями», поиск сообществ.

## План (следующие шаги редизайна)

Макет и `docs/design-system.md` — ориентир. Шаги согласованы с пользователем:

2. **Экран поста** (`Route.post`, сейчас заглушка): пост целиком, голоса,
   древовидные комментарии плоским списком по `depth` (UIKit, как лента),
   «Ответить» из комментария, поле ввода внизу, `more`/`continue`, голоса за
   комментарии (оптимистично), переход к родителю. Бэкенд готов:
   `GET /v1/posts/{id}`, `/comments`, `/v1/comments/{id}/replies`, `POST …/comments`,
   `PUT /v1/comments/{id}/vote`. При переходе позиция ленты сохраняется (стек).
   Голоса поста в ленте и на экране поста стоит связать общим `PostStore`.
3. **Создание поста** (центральный «+», сейчас `ComposePlaceholder`): текст,
   выбор сообщества, публикация (`POST /v1/communities/{slug}/posts`).
4. **Сообщества/страница сообщества/профиль** в новом стиле; кнопка
   «Подписаться» (оптимистично), вкладки «Лента / Популярное / Правила».
5. **Медиа**: бэкенд (S3/MinIO presigned, imgproxy, таблица `media` уже есть)
   + картинки/аватары/обложки в приложении.
6. **Поиск постов и людей, Активность (уведомления), закладки** — нужен бэкенд.

TODO из `docs/architecture.md`: Telegram в iOS, восстановление пароля, адрес
клиента за прокси, снимок «горячего», WebSocket, кэш ленты (GRDB), тост при
ошибке голоса, «Сохранить/Пожаловаться/Скрыть», иконка приложения, отзыв токена
Apple при удалении аккаунта.

## Грабли, на которые уже наступили

- Swift 6.1: в `Task {}` нет вывода типизированных ошибок — писать
  `do throws(APIError) { … } catch { switch error … }`.
- Вложенный тип `Body` внутри `ButtonStyle` конфликтует с ассоциированным типом.
- В `project.pbxproj` у `XCSwiftPackageProductDependency` локального пакета
  обязателен `package = <XCLocalSwiftPackageReference>`. Правки pbxproj делать
  скриптом и проверять `plutil -lint` + сборкой. Новые модули пакета Xcode у
  пользователя иногда не видит — помогает Reset Package Caches / чистка DerivedData.
- Swift Testing: `#expect` внутри обработчика `URLProtocol` роняет процесс —
  только записывать запросы, проверять в теле теста.
- XCUITest не может ввести латиницу в `SecureField` при русской клавиатуре
  симулятора (поэтому нет UI-теста входа). Системный алерт «Открыть в
  приложении?» при deep link нужно подтверждать через springboard.
- В macOS нет `timeout`; zsh не разбивает `$VAR` с пробелами на слова — для
  команд с аргументами использовать функции.
- Даты от Go: RFC 3339 с дробью и без — `JSON.decoder()` понимает оба.
- Миграции: уже применённые не редактировать, только новые файлы.
