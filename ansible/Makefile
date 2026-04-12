SHELL := /bin/bash

ENV ?= prod
INVENTORY := inventories/$(ENV)/hosts.yml
PLAYBOOK_DEPLOY := playbooks/deploy.yml
PLAYBOOK_STATUS := playbooks/status.yml
VARS := -e @group_vars/all.yml -e @group_vars/$(ENV).yml -e @group_vars/vault.yml
ASK_FLAGS ?= --ask-vault-pass -K
COMMON := ANSIBLE_ROLES_PATH=./roles ansible-playbook -i $(INVENTORY) -c local $(VARS) $(ASK_FLAGS)

.PHONY: help ping deploy deploy-target status status-target smoke

help:
	@echo "make deploy                          # full deploy for ENV=$(ENV)"
	@echo "make deploy-target SERVICE=auth_service"
	@echo "make status                          # docker compose status for all services"
	@echo "make status-target SERVICE=users_service"
	@echo "make smoke SERVICE_TOKEN=...         # run scripts/smoke_prod.sh"
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

status:
	$(COMMON) $(PLAYBOOK_STATUS)

status-target:
	@test -n "$(SERVICE)" || (echo "SERVICE is required, e.g. make status-target SERVICE=users_service" && exit 1)
	$(COMMON) $(PLAYBOOK_STATUS) -e '{"target_services":["$(SERVICE)"]}'

smoke:
	@test -n "$(SERVICE_TOKEN)" || (echo "SERVICE_TOKEN is required, e.g. make smoke SERVICE_TOKEN=sometokencourse" && exit 1)
	SERVICE_TOKEN="$(SERVICE_TOKEN)" ./scripts/smoke_prod.sh

