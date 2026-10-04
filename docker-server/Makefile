.PHONY: prepare up down deploy smoke logs ps

prepare:
	./harbor/prepare.sh

up:
	docker compose -f harbor/docker-compose.yml --env-file harbor/.env up -d

down:
	./scripts/down.sh

deploy:
	./scripts/deploy.sh

smoke:
	./scripts/smoke-test.sh

logs:
	docker compose -f harbor/docker-compose.yml --env-file harbor/.env logs -f --tail=200

ps:
	docker compose -f harbor/docker-compose.yml --env-file harbor/.env ps
