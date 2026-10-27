# Ветка

iOS-приложение сообществ для СНГ (гибрид Reddit и Пикабу).

- `ios/` — SwiftUI/UIKit, iOS 17+
- `backend/` — Go (chi, pgx, sqlc), PostgreSQL, Redis, S3, WebSocket
- `infra/` — Docker Compose для локальной разработки
- `docs/architecture.md` — ключевые решения

```bash
docker compose -f infra/docker-compose.yml up -d
```
