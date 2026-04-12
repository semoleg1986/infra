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

## Важно
- Замените `ghcr.io/your-org/*` на реальные образы.
- Реальные секреты храните в `ansible-vault` (`group_vars/vault.yml`).
- Для production используйте фиксированные теги образов, не `latest`.
- Для связки `course_service -> users_service` задайте `users_service_token` (или `vault_users_service_token`).
- Сервисы деплоятся per-service compose, но в единую внешнюю сеть `{{ docker_shared_network | default('curs_net') }}`.

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
  - Пример запуска:
    ```bash
    chmod +x scripts/smoke_prod.sh
    SERVICE_TOKEN='your-internal-token' ./scripts/smoke_prod.sh
    ```

## Post-Deploy Smoke (Prod)
- В `group_vars/prod.yml` включен `post_deploy_smoke_enabled: true`.
- После `playbooks/deploy.yml` автоматически запускается `scripts/smoke_prod.sh`.
- Smoke запускается, только если в деплое есть все сервисы из `post_deploy_smoke_required_services`:
  - `auth_service`
  - `users_service`
  - `course_service`
- Для частичного деплоя playbook печатает сообщение, что smoke пропущен.
- Временное отключение:
  ```bash
  ansible-playbook -i inventories/prod/hosts.yml playbooks/deploy.yml \
    -e post_deploy_smoke_enabled=false
  ```
