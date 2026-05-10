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
  make dispatch-outbox
  make dispatch-payments-outbox
  make dispatch-course-outbox
  make load-auth-burst
  make load-live-room-burst
  make load-payment-access-progress
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
- Для `bonus_wallet_service` задайте `bonus_wallet_service_token` (или `vault_bonus_wallet_service_token`).
- Для runtime hardening можно задать лимиты контейнеров:
  - `service_default_resources` (общие лимиты для всех сервисов),
  - `service_resources_overrides` (точечные overrides по имени сервиса).
- Для network exposure baseline доступны bind-host knobs:
  - `api_public_bind_host` — bind для API сервисов (по умолчанию `0.0.0.0`)
  - `web_public_bind_host` — bind для web/admin/studio (по умолчанию `0.0.0.0`)
  - `observability_bind_host` — bind для Prometheus/Grafana (по умолчанию `127.0.0.1`)
  - Это позволяет ужесточать surface area без полной перестройки compose-шаблона.
- Docker daemon log rotation также управляется через Ansible (`roles/docker`):
  - `docker_log_driver` (по умолчанию `json-file`)
  - `docker_log_max_size` (по умолчанию `10m`)
  - `docker_log_max_file` (по умолчанию `5`)
- Сервисы деплоятся per-service compose, но в единую внешнюю сеть `{{ docker_shared_network | default('curs_net') }}`.
- Production управляется только через Ansible (`/opt/curs/*` compose-файлы).
- Не запускайте параллельно `docker compose` из `~/apps/curs`, чтобы не получать конфликты `container_name`.
- Для `auth_service`, `users_service`, `course_service`, `attribution_service`, `payments_service`, `bonus_wallet_service` миграции запускаются автоматически (`alembic upgrade head`) перед стартом контейнера.
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
   for db in auth_service_prod_drill users_service_prod_drill course_service_prod_drill attribution_service_prod_drill live_class_service_prod_drill payments_service_prod_drill bonus_wallet_service_prod_drill; do
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
  - periodic outbox drain (`make dispatch-outbox`)
- Outbox automation defaults:
  - расписание: `ops_cron_outbox_dispatch_time="*/5 * * * *"`
  - лимит: `ops_cron_outbox_dispatch_limit="100"`
  - lock: `/var/lock/curs-outbox.lock`

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

## Outbox Dispatch Ops
- Ручной drain outbox для бонусного/платежного контура:
  ```bash
  make dispatch-outbox
  ```
- Только `payments_service`:
  ```bash
  make dispatch-payments-outbox
  ```
- Только `course_service`:
  ```bash
  make dispatch-course-outbox
  ```
- Лимит можно переопределить:
  ```bash
  LIMIT=200 make dispatch-outbox
  ```
- В `prod` автоматический drain ставится через `/etc/cron.d/curs-ops`
  и запускает `make dispatch-outbox` каждые 5 минут с `flock`.

## Load Baseline (Sprint 6 - 3.2)
- Первый server-side сценарий:
  - `scripts/load/auth-burst.k6.js`
- Обертка запуска:
  - `scripts/load_auth_burst.sh`
- Команда:
  ```bash
  make load-auth-burst
  ```
- По умолчанию сценарий:
  - бьет в `AUTH_BASE_URL=http://127.0.0.1:8000`
  - запускается как `K6_VUS=20`
  - работает `K6_DURATION=2m`
  - регистрирует pool пользователей `K6_USER_POOL_SIZE` (по умолчанию `max(K6_VUS * 50, 1000)`), чтобы не утыкаться в login rate-limit на одном email
  - разрешает длинный `setup()` через `K6_SETUP_TIMEOUT=15m`
  - использует Docker image `grafana/k6:0.49.0`
- Важно:
  - отдельная установка `k6` на сервер не нужна
  - запуск идет через `docker run --network host`
  - для первого безопасного прогона лучше оставить дефолтный профиль и только потом повышать `K6_VUS`
- Полезные overrides:
  ```bash
  AUTH_BASE_URL=http://127.0.0.1:8000 K6_VUS=50 K6_DURATION=3m K6_USER_POOL_SIZE=2500 K6_SETUP_TIMEOUT=20m make load-auth-burst
  ```
- Использование существующего аккаунта вместо auto-register:
  ```bash
  AUTH_REGISTER_ENABLED=false \
  AUTH_EMAIL=load.user@example.com \
  AUTH_PASSWORD=LoadTest12345! \
  make load-auth-burst
  ```
- Важно:
  - если использовать один существующий аккаунт, сценарий почти наверняка упрется в `AUTH_RATE_LIMIT_LOGIN_MAX`
  - для throughput baseline лучше оставлять auto-register pool mode

- Второй server-side сценарий:
  - `scripts/load/live-room-burst.k6.js`
- Обертка запуска:
  - `scripts/load_live_room_burst.sh`
- Команда:
  ```bash
  make load-live-room-burst
  ```
- По умолчанию сценарий:
  - логинится admin-пользователем
  - в `setup()` поднимает teacher/course/published lesson
  - создает parent + pool student-аккаунтов
  - выдает course access через `payments_service`
  - создает один live room с лимитом участников выше пула
  - в основном цикле каждый VU работает со своим student identity:
    - `join`
    - `leave`
    - `attendance read`
- Полезные overrides:
  ```bash
  K6_VUS=20 K6_DURATION=2m K6_USER_POOL_SIZE=20 K6_ROOM_POOL_SIZE=20 K6_SETUP_TIMEOUT=20m make load-live-room-burst
  ```
- Важно:
  - этот профиль намеренно не меряет auth rate-limit
  - он нужен как baseline именно для `live join / leave / attendance`
  - чтобы не мерить artificial optimistic-lock contention на одной комнате, можно разносить `VU` по пулу комнат через `K6_ROOM_POOL_SIZE`

- Третий server-side сценарий:
  - `scripts/load/payment-access-progress.k6.js`
- Обертка запуска:
  - `scripts/load_payment_access_progress.sh`
- Команда:
  ```bash
  make load-payment-access-progress
  ```
- По умолчанию сценарий:
  - логинится admin-пользователем
  - в `setup()` поднимает teacher/course/two published lessons
  - создает parent + student pool
  - основной цикл выполняет:
    - `POST /v1/parent/payments/intents`
    - `POST /v1/admin/payments/{id}/approve`
    - `GET /internal/v1/access/{course_id}/{student_id}`
    - `POST /v1/student/courses/{course_id}/lessons/{lesson_id}/complete`
    - `GET /v1/student/courses/{course_id}/progress`
    - `GET /v1/parent/students/{student_id}/courses/progress`
    - `GET /v1/parent/students/{student_id}/courses/completed`
- Полезные overrides:
  ```bash
  K6_VUS=5 K6_DURATION=2m K6_USER_POOL_SIZE=5 K6_SETUP_TIMEOUT=20m make load-payment-access-progress
  ```

## Chaos / Failure Drill (Sprint 6 - 3.3)
- Первый server-side drill:
  - `scripts/chaos_auth_restart.sh`
- Обертка запуска:
  - `make chaos-auth-restart`
- Что делает:
  - многократно выполняет:
    - `POST /v1/auth/login`
    - `GET /v1/auth/me`
    - `GET /v1/admin/users?limit=1&offset=0`
  - посередине цикла делает `docker restart curs_auth_service`
  - сравнивает `JWKS kid` до и после рестарта
  - печатает итог:
    - восстановился ли `auth_service`
    - принимает ли `users_service` свежие токены после рестарта
- Команда:
  ```bash
  make chaos-auth-restart
  ```
- Полезные overrides:
  ```bash
  AUTH_BASE_URL=http://127.0.0.1:8000 \
  USERS_BASE_URL=http://127.0.0.1:8002 \
  CHAOS_ITERATIONS=30 \
  CHAOS_INTERVAL_SECONDS=1 \
  CHAOS_RESTART_AT_ITERATION=10 \
  make chaos-auth-restart
  ```
- Важно:
  - если `auth_service` все еще использует ephemeral JWT keys, drill может завершиться кодом `2`
  - это будет означать: `auth` уже поднялся, но `users_service` продолжает держать stale JWKS cache
  - после перевода `auth_service` на persistent JWT keys этот drill должен становиться полностью зеленым без ручного рестарта consumers

- Второй server-side drill:
  - `scripts/chaos_users_restart.sh`
- Обертка запуска:
  - `make chaos-users-restart`
- Что делает:
  - многократно выполняет:
    - `POST /v1/auth/login`
    - `GET /v1/auth/me`
    - `GET /v1/admin/users?limit=1&offset=0`
    - `GET /healthz` для `users_service` после restart
  - посередине цикла делает `docker restart curs_users_service`
  - печатает итог:
    - оставался ли `auth_service` доступным
    - восстановился ли `users_service` в пределах окна drill
- Команда:
  ```bash
  make chaos-users-restart
  ```
- Полезные overrides:
  ```bash
  AUTH_BASE_URL=http://127.0.0.1:8000 \
  USERS_BASE_URL=http://127.0.0.1:8002 \
  CHAOS_ITERATIONS=30 \
  CHAOS_INTERVAL_SECONDS=1 \
  CHAOS_RESTART_AT_ITERATION=10 \
  make chaos-users-restart
  ```

- Третий server-side drill:
  - `scripts/chaos_payments_restart.sh`
- Обертка запуска:
  - `make chaos-payments-restart`
- Что делает:
  - в bootstrap поднимает минимальный контур:
    - teacher
    - course
    - parent + student
    - parent-student link
  - потом многократно выполняет:
    - `POST /v1/parent/payments/intents`
    - `POST /v1/admin/payments/{id}/approve`
    - `GET /internal/v1/access/{course_id}/{student_id}`
    - `GET /healthz` для `payments_service` после restart
  - посередине цикла делает `docker restart curs_payments_service`
  - печатает итог:
    - восстановился ли `create-intent` path
    - восстановился ли `access-check` path
- Команда:
  ```bash
  SERVICE_TOKEN=sometokencourse make chaos-payments-restart
  ```
- Полезные overrides:
  ```bash
  AUTH_BASE_URL=http://127.0.0.1:8000 \
  USERS_BASE_URL=http://127.0.0.1:8002 \
  COURSE_BASE_URL=http://127.0.0.1:8001 \
  PAYMENTS_BASE_URL=http://127.0.0.1:8004 \
  SERVICE_TOKEN=sometokencourse \
  CHAOS_ITERATIONS=20 \
  CHAOS_INTERVAL_SECONDS=1 \
  CHAOS_RESTART_AT_ITERATION=8 \
  make chaos-payments-restart
  ```

- Optional infra-level drill:
  - `scripts/chaos_redis_live.sh`
- Обертка запуска:
  - `make chaos-redis-live`
- Что делает:
  - в bootstrap поднимает минимальный contour для `live_class_service`:
    - teacher
    - published course/lesson
    - parent + student
    - parent-student link
    - payment access
    - live room
  - потом многократно выполняет:
    - `POST /v1/live/rooms/{roomId}/join`
    - `POST /v1/live/rooms/{roomId}/leave`
    - `GET /v1/live/rooms/{roomId}/attendance`
    - `GET /healthz` у `live_class_service` после restart
  - посередине цикла делает `docker restart curs_redis`
  - печатает итог:
    - восстановился ли join path
    - восстановился ли attendance path
- Команда:
  ```bash
  SERVICE_TOKEN=sometokencourse make chaos-redis-live
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
