SHELL := /bin/bash

ENV ?= prod
INVENTORY := inventories/$(ENV)/hosts.yml
PLAYBOOK_DEPLOY := playbooks/deploy.yml
PLAYBOOK_STATUS := playbooks/status.yml
VARS := -e @group_vars/all.yml -e @group_vars/$(ENV).yml -e @group_vars/vault.yml
ASK_FLAGS ?= --ask-vault-pass -K
COMMON := ANSIBLE_ROLES_PATH=./roles ansible-playbook -i $(INVENTORY) -c local $(VARS) $(ASK_FLAGS)

.PHONY: help ping deploy deploy-target rollback status status-target smoke smoke-problem-json smoke-student-invite-web backup-postgres backup-rotate restore-drill restore-cleanup ops-check dispatch-outbox dispatch-payments-outbox dispatch-course-outbox load-auth-burst load-auth-throttle-guard load-live-room-burst load-payment-access-progress load-payment-bonus-checkout load-payment-throttle-guard chaos-auth-restart chaos-users-restart chaos-payments-restart chaos-redis-live

help:
	@echo "make deploy                          # full deploy for ENV=$(ENV)"
	@echo "make deploy-target SERVICE=auth_service"
	@echo "make rollback SERVICE=auth_service TAG=main"
	@echo "make status                          # docker compose status for all services"
	@echo "make status-target SERVICE=users_service"
	@echo "make smoke SERVICE_TOKEN=...         # run scripts/smoke_prod.sh"
	@echo "make smoke-problem-json SERVICE_TOKEN=... # check error contract for backend services"
	@echo "make smoke-student-invite-web PARENT_PASSWORD=... # run web invite onboarding smoke"
	@echo "make backup-postgres                 # create dumps in ~/backups/postgres/<timestamp>"
	@echo "make backup-rotate                   # rotate backup dirs by age/count"
	@echo "make restore-drill BACKUP_DIR=...    # restore dumps into *_drill DBs"
	@echo "make restore-cleanup                 # drop *_drill DBs one by one"
	@echo "make ops-check                       # disk/health/5xx baseline check"
	@echo "make dispatch-outbox                 # drain payments+course outbox inside containers"
	@echo "make dispatch-payments-outbox        # drain only payments_service outbox"
	@echo "make dispatch-course-outbox          # drain only course_service outbox"
	@echo "make load-auth-burst                 # run server-side auth success baseline via Dockerized k6"
	@echo "make load-auth-throttle-guard        # run auth login pressure profile to observe 429 guard behavior"
	@echo "make load-live-room-burst            # run server-side live join/leave baseline via Dockerized k6"
	@echo "make load-payment-access-progress    # run offer-based success-baseline checkout via Dockerized k6"
	@echo "make load-payment-bonus-checkout     # run offer-based payment+bonus checkout baseline via Dockerized k6"
	@echo "make load-payment-throttle-guard     # run repeated checkout pressure to observe 429/guard behavior"
	@echo "make chaos-auth-restart              # restart auth_service mid-drill and verify recovery"
	@echo "make chaos-users-restart             # restart users_service mid-drill and verify recovery"
	@echo "make chaos-payments-restart          # restart payments_service mid-drill and verify recovery"
	@echo "make chaos-redis-live                # restart redis mid-drill and verify live recovery"
	@echo "make ping                            # ansible ping"

ping:
	ansible -i $(INVENTORY) app -m ping -c local -K

deploy:
	$(COMMON) $(PLAYBOOK_DEPLOY)

deploy-target:
	@test -n "$(SERVICE)" || (echo "SERVICE is required, e.g. make deploy-target SERVICE=auth_service" && exit 1)
	$(COMMON) $(PLAYBOOK_DEPLOY) \
		-e '{"target_services":["$(SERVICE)"]}' \
		--start-at-task "Validate selected services"

rollback:
	@test -n "$(SERVICE)" || (echo "SERVICE is required, e.g. make rollback SERVICE=auth_service TAG=main" && exit 1)
	@test -n "$(TAG)" || (echo "TAG is required, e.g. make rollback SERVICE=auth_service TAG=main" && exit 1)
	$(COMMON) $(PLAYBOOK_DEPLOY) \
		-e '{"target_services":["$(SERVICE)"],"service_image_tags":{"$(SERVICE)":"$(TAG)"}}' \
		--start-at-task "Validate selected services"

status:
	$(COMMON) $(PLAYBOOK_STATUS)

status-target:
	@test -n "$(SERVICE)" || (echo "SERVICE is required, e.g. make status-target SERVICE=users_service" && exit 1)
	$(COMMON) $(PLAYBOOK_STATUS) -e '{"target_services":["$(SERVICE)"]}'

smoke:
	@test -n "$(SERVICE_TOKEN)" || (echo "SERVICE_TOKEN is required, e.g. make smoke SERVICE_TOKEN=sometokencourse" && exit 1)
	SERVICE_TOKEN="$(SERVICE_TOKEN)" ./scripts/smoke_prod.sh

smoke-problem-json:
	@test -n "$(SERVICE_TOKEN)" || (echo "SERVICE_TOKEN is required, e.g. make smoke-problem-json SERVICE_TOKEN=sometokencourse" && exit 1)
	SERVICE_TOKEN="$(SERVICE_TOKEN)" SMOKE_PROBLEM_JSON_ONLY=1 SMOKE_PAYMENTS_ENABLED=1 SMOKE_BONUS_ENABLED=1 SMOKE_ATTRIBUTION_ENABLED=1 ./scripts/smoke_prod.sh

smoke-student-invite-web:
	@test -n "$(PARENT_PASSWORD)" || (echo "PARENT_PASSWORD is required" && exit 1)
	WEB_BASE_URL="$(WEB_BASE_URL)" PARENT_EMAIL="$(PARENT_EMAIL)" PARENT_PASSWORD="$(PARENT_PASSWORD)" STUDENT_PASSWORD="$(STUDENT_PASSWORD)" ./scripts/smoke_student_invite_web.sh

backup-postgres:
	./scripts/pg_backup.sh

backup-rotate:
	./scripts/backup_rotate.sh

restore-drill:
	@test -n "$(BACKUP_DIR)" || (echo "BACKUP_DIR is required, e.g. make restore-drill BACKUP_DIR=~/backups/postgres/20260419_120000" && exit 1)
	BACKUP_DIR="$(BACKUP_DIR)" ./scripts/pg_restore_drill.sh

restore-cleanup:
	bash ./scripts/pg_restore_cleanup.sh

ops-check:
	./scripts/ops_baseline_check.sh

dispatch-outbox:
	LIMIT="$(LIMIT)" SERVICE=all bash ./scripts/dispatch_outbox.sh

dispatch-payments-outbox:
	LIMIT="$(LIMIT)" SERVICE=payments_service bash ./scripts/dispatch_outbox.sh

dispatch-course-outbox:
	LIMIT="$(LIMIT)" SERVICE=course_service bash ./scripts/dispatch_outbox.sh

load-auth-burst:
	./scripts/load_auth_burst.sh

load-auth-throttle-guard:
	./scripts/load_auth_throttle_guard.sh

load-live-room-burst:
	./scripts/load_live_room_burst.sh

load-live-room-throttle-guard:
	./scripts/load_live_room_throttle_guard.sh

load-payment-access-progress:
	./scripts/load_payment_access_progress.sh

load-payment-bonus-checkout:
	./scripts/load_payment_bonus_checkout.sh

load-payment-throttle-guard:
	./scripts/load_payment_throttle_guard.sh

chaos-auth-restart:
	./scripts/chaos_auth_restart.sh

chaos-users-restart:
	./scripts/chaos_users_restart.sh

chaos-payments-restart:
	./scripts/chaos_payments_restart.sh

chaos-redis-live:
	SERVICE_TOKEN="$(SERVICE_TOKEN)" ./scripts/chaos_redis_live.sh
