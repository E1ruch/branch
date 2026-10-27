# Переменные из .env (если есть) уходят в окружение всех команд.
-include .env
# Интеграционные тесты создают себе отдельную БД на каждый тест.
TEST_DATABASE_URL ?= postgres://vetka:vetka@localhost:5432/vetka?sslmode=disable
export

COMPOSE := docker compose -f ../infra/docker-compose.yml

.PHONY: infra-up infra-down migrate run worker test vet

infra-up:
	$(COMPOSE) up -d --wait

infra-down:
	$(COMPOSE) down

migrate:
	go run ./cmd/migrate up

run:
	go run ./cmd/api

# Применяет голоса к счётчикам; без него счёт и «горячее» не двигаются.
worker:
	go run ./cmd/worker

test:
	go test -race ./...

vet:
	go vet ./...
