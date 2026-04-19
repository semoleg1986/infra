SHELL := /bin/bash

ENV ?= prod
INVENTORY := inventories/$(ENV)/hosts.yml
PLAYBOOK_DEPLOY := playbooks/deploy.yml
PLAYBOOK_STATUS := playbooks/status.yml
VARS := -e @group_vars/all.yml -e @group_vars/$(ENV).yml -e @group_vars/vault.yml
ASK_FLAGS ?= --ask-vault-pass -K
COMMON := ANSIBLE_ROLES_PATH=./roles ansible-playbook -i $(INVENTORY) -c local $(VARS) $(ASK_FLAGS)

.PHONY: help ping deploy deploy-target rollback status status-target smoke backup-postgres backup-rotate restore-drill ops-check

help:
	@echo "make deploy                          # full deploy for ENV=$(ENV)"
	@echo "make deploy-target SERVICE=auth_service"
	@echo "make rollback SERVICE=auth_service TAG=main"
	@echo "make status                          # docker compose status for all services"
	@echo "make status-target SERVICE=users_service"
	@echo "make smoke SERVICE_TOKEN=...         # run scripts/smoke_prod.sh"
	@echo "make backup-postgres                 # create dumps in ~/backups/postgres/<timestamp>"
	@echo "make backup-rotate                   # rotate backup dirs by age/count"
	@echo "make restore-drill BACKUP_DIR=...    # restore dumps into *_drill DBs"
	@echo "make ops-check                       # disk/health/5xx baseline check"
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

backup-postgres:
	./scripts/pg_backup.sh

backup-rotate:
	./scripts/backup_rotate.sh

restore-drill:
	@test -n "$(BACKUP_DIR)" || (echo "BACKUP_DIR is required, e.g. make restore-drill BACKUP_DIR=~/backups/postgres/20260419_120000" && exit 1)
	BACKUP_DIR="$(BACKUP_DIR)" ./scripts/pg_restore_drill.sh

ops-check:
	./scripts/ops_baseline_check.sh
