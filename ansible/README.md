# Ansible deploy scaffold

Каркас деплоя микросервисов через Docker Compose (per-service) на удаленный сервер.

## Структура
- `inventories/{dev,stage,prod}/hosts.yml` — хосты окружений.
- `group_vars/all.yml` — общий каталог сервисов и их env/ports/image.
- `playbooks/bootstrap.yml` — базовая подготовка хоста.
- `playbooks/deploy.yml` — деплой выбранных сервисов.
- `playbooks/status.yml` — просмотр статуса сервисов.
- `roles/compose_service` — универсальная роль деплоя сервиса.

## Быстрый старт
0. Заполнить `inventories/prod/hosts.yml` (IP, user, key) и `group_vars/vault.yml`.

1. Установить коллекции:
```bash
ansible-galaxy collection install -r requirements.yml
```

2. Проверить inventory:
```bash
ansible-inventory -i inventories/dev/hosts.yml --graph
```

3. Проверить доступ по SSH:
```bash
ansible -i inventories/dev/hosts.yml app -m ping
```

4. Bootstrap:
```bash
ansible-playbook -i inventories/dev/hosts.yml playbooks/bootstrap.yml
```

5. Деплой всех сервисов:
```bash
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml
```

6. Деплой только выбранных сервисов:
```bash
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml \
  -e '{"target_services": ["auth_service", "users_service"]}'
```

7. Статус:
```bash
ansible-playbook -i inventories/dev/hosts.yml playbooks/status.yml
```

## Makefile
- Быстрые команды:
  ```bash
  make deploy
  make deploy-target SERVICE=auth_service
  make rollback SERVICE=auth_service TAG=main
  make status
  make status-target SERVICE=users_service
  make smoke SERVICE_TOKEN=sometokencourse
  make backup-postgres
  make backup-rotate
  make restore-drill BACKUP_DIR=~/backups/postgres/<timestamp>
  make ops-check
  ```
- По умолчанию используется `ENV=prod`. Для другого окружения:
  ```bash
  make ENV=stage deploy
  ```

## Rollback
- Быстрый точечный rollback сервиса на нужный тег:
  ```bash
  make rollback SERVICE=course_service TAG=main
  ```
- Команда временно переопределяет `service_image_tags.<SERVICE>=<TAG>` через `-e` и деплоит только этот сервис.

## Важно
- Замените `ghcr.io/your-org/*` на реальные образы.
- Реальные секреты храните в `ansible-vault` (`group_vars/vault.yml`).
- Для production используйте фиксированные теги образов, не `latest`.
  - Теги задаются в `group_vars/prod.yml -> service_image_tags`.
- Для связки `course_service -> users_service` задайте `users_service_token` (или `vault_users_service_token`).
- Для `payments_service` задайте `payments_service_token` (или `vault_payments_service_token`).
- Для связки `payments_service -> attribution_service` задайте `attribution_service_token` (или `vault_attribution_service_token`).
- Для runtime hardening можно задать лимиты контейнеров:
  - `service_default_resources` (общие лимиты для всех сервисов),
  - `service_resources_overrides` (точечные overrides по имени сервиса).
- Docker daemon log rotation также управляется через Ansible (`roles/docker`):
  - `docker_log_driver` (по умолчанию `json-file`)
  - `docker_log_max_size` (по умолчанию `10m`)
  - `docker_log_max_file` (по умолчанию `5`)
- Сервисы деплоятся per-service compose, но в единую внешнюю сеть `{{ docker_shared_network | default('curs_net') }}`.
- Production управляется только через Ansible (`/opt/curs/*` compose-файлы).
- Не запускайте параллельно `docker compose` из `~/apps/curs`, чтобы не получать конфликты `container_name`.
- Для `auth_service`, `users_service`, `course_service`, `attribution_service`, `payments_service` миграции запускаются автоматически (`alembic upgrade head`) перед стартом контейнера.
- Перед миграцией добавлен pre-check рассинхрона (`schema есть, alembic_version пуст`) с автоматическим `alembic stamp` по сервисному revision guard.

## GHCR
- В репозитории есть workflows сборки и публикации образов в GHCR для всех сервисов.
- Если пакеты приватные: включите в `group_vars/prod.yml`
  - `ghcr_require_login: true`
  - `ghcr_username: "{{ vault_ghcr_username }}"`
  - `ghcr_token: "{{ vault_ghcr_token }}"`
- Роль `docker` выполнит `docker login ghcr.io` перед деплоем.

## Secrets
- Шаблон секретов: `group_vars/vault.template.yml`
- Рабочий файл: `group_vars/vault.yml` (зашифрованный `ansible-vault`)

## Stage QA
- Чек-лист smoke-проверки после деплоя: `STAGE_SMOKE_CHECKLIST.md`
- Автоматизированный smoke-скрипт prod-контура: `scripts/smoke_prod.sh`
  - Поддерживает расширенный шаг для `payments_service` (включается автоматически при деплое `payments_service`).
  - Пример запуска:
    ```bash
    chmod +x scripts/smoke_prod.sh
    SERVICE_TOKEN='your-internal-token' ./scripts/smoke_prod.sh
    ```

## Post-Deploy Smoke (Prod)
- В `group_vars/all.yml` включен `post_deploy_smoke_enabled: true` (при необходимости переопределяется в `group_vars/prod.yml`).
- После `playbooks/deploy.yml` автоматически запускается `scripts/smoke_prod.sh`.
- Smoke запускается, только если в деплое есть все сервисы из `post_deploy_smoke_required_services`:
  - `auth_service`
  - `users_service`
  - `course_service`
  - `payments_service`
- Для частичного деплоя playbook печатает сообщение, что smoke пропущен.
- Временное отключение:
  ```bash
  ansible-playbook -i inventories/prod/hosts.yml playbooks/deploy.yml \
    -e post_deploy_smoke_enabled=false
  ```

## CI E2E
- Workflow: `.github/workflows/e2e-contour-smoke.yml`
- Поднимает `auth_service + users_service + course_service + payments_service` из GHCR и запускает `ansible/scripts/smoke_prod.sh`.

## Postgres Backup / Restore Drill
- Скрипт бэкапа: `scripts/pg_backup.sh`
- Скрипт restore-drill: `scripts/pg_restore_drill.sh`
- Скрипт ротации: `scripts/backup_rotate.sh`

1. Создать бэкап:
   ```bash
   make backup-postgres
   ```
   По умолчанию dump-файлы создаются в `~/backups/postgres/<timestamp>`.

2. Выполнить restore-drill в отдельные БД с суффиксом `_drill`:
   ```bash
   make restore-drill BACKUP_DIR=~/backups/postgres/<timestamp>
   ```

3. Проверить список drill-баз:
   ```bash
   sudo docker exec curs_postgres psql -U postgres -d postgres -lqt | grep _drill
   ```

4. (Опционально) удалить drill-базы после проверки:
   ```bash
   for db in auth_service_prod_drill users_service_prod_drill course_service_prod_drill attribution_service_prod_drill live_class_service_prod_drill payments_service_prod_drill; do
     sudo docker exec curs_postgres psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS \"$db\";"
  done
  ```

5. Ротация старых бэкапов:
   ```bash
   make backup-rotate
   ```
   По умолчанию: `KEEP_DAYS=14`, `KEEP_LAST=14`.

### Nightly schedule (cron пример)
```bash
crontab -e
```
Добавьте:
```cron
15 2 * * * cd /home/deploy/apps/infra/ansible && /usr/bin/make backup-postgres >> /home/deploy/backups/postgres/backup.log 2>&1
45 2 * * * cd /home/deploy/apps/infra/ansible && KEEP_DAYS=14 KEEP_LAST=14 /usr/bin/make backup-rotate >> /home/deploy/backups/postgres/backup.log 2>&1
```

### Nightly schedule через Ansible (рекомендуется)
- Cron-файл хранится в git и накатывается через `playbooks/deploy.yml`:
  - шаблон: `templates/curs-ops.cron.j2`
  - целевой файл на сервере: `/etc/cron.d/curs-ops`
- Управление:
  - `group_vars/all.yml`: дефолты (`ops_cron_*`)
  - `group_vars/prod.yml`: `ops_cron_enabled: true`
- Что ставится автоматически:
  - daily backup (`make backup-postgres`)
  - daily rotate (`make backup-rotate`)
  - weekly restore drill (`make restore-drill`)
  - weekly cleanup `*_drill` баз
  - weekly `docker image prune -a -f`

## Ops Baseline Check
- Скрипт: `scripts/ops_baseline_check.sh`
- Команда:
  ```bash
  make ops-check
  ```
- Что проверяет:
  - заполнение `/` (warn/crit пороги),
  - статус docker-контейнеров (`Up`/`unhealthy`),
  - HTTP health endpoints сервисов,
  - признаки 5xx/Traceback в последних логах контейнеров.

- Полезные overrides:
  ```bash
  DISK_WARN_PCT=85 DISK_CRIT_PCT=92 LOG_5XX_WARN_COUNT=3 make ops-check
  ```

## Alerts & Dashboard (Sprint 5 - 2.3)
- Готовые артефакты:
  - Prometheus alerts: `files/observability/prometheus-alerts.yml`
  - Prometheus config: `files/observability/prometheus.yml`
  - Grafana dashboard: `files/observability/grafana-dashboard-curs-api.json`
  - Grafana provisioning:
    - `files/observability/grafana-datasource.yml`
    - `files/observability/grafana-dashboards.yml`

- Через Ansible:
  1. В `group_vars/prod.yml` включены:
     - `prometheus_enabled: true`
     - `grafana_enabled: true`
  2. Деплой:
     ```bash
     make deploy-target SERVICE=prometheus
     make deploy-target SERVICE=grafana
     ```
  3. Проверка:
     - Prometheus: `http://<host>:9090`
     - Grafana: `http://<host>:3005` (admin/admin если не переопределено vault vars)

- Правила алертов из коробки:
  - `CursApi5xxDetected`
  - `CursApiHigh5xxRatio`
  - `CursApiHighAvgLatency`
