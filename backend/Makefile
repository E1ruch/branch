# Переменные из .env (если есть) уходят в окружение всех команд.
-include .env
export

COMPOSE := docker compose -f ../infra/docker-compose.yml

.PHONY: infra-up infra-down migrate run test vet

infra-up:
	$(COMPOSE) up -d --wait

infra-down:
	$(COMPOSE) down

migrate:
	go run ./cmd/migrate up

run:
	go run ./cmd/api

test:
	go test -race ./...

vet:
	go vet ./...
