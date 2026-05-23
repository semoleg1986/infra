# infra / ansible

Operational entrypoint for deploy, smoke, load, backup, restore, and chaos drills.

## Main commands

```bash
cd infra/ansible
make help
```

Most used targets:
```bash
make deploy-target SERVICE=web_app
make status-target SERVICE=payments_service
make smoke SERVICE_TOKEN=...
make smoke-student-invite-web PARENT_PASSWORD=...
make backup-postgres
make restore-drill BACKUP_DIR=...
make restore-cleanup
```

## Deploy

Single service:
```bash
make deploy-target SERVICE=payments_service
```

Full deploy:
```bash
make deploy
```

## Smoke

```bash
make smoke SERVICE_TOKEN=...
```

Direct script call when you need extra flags:
```bash
SERVICE_TOKEN=... \
SMOKE_PAYMENTS_ENABLED=1 \
SMOKE_PAYMENTS_AUTO_CREATE_OFFER=1 \
bash ./scripts/smoke_prod.sh
```

Student invite web smoke:

```bash
WEB_BASE_URL=http://127.0.0.1:3000 \
PARENT_EMAIL=test3parent@mail.com \
PARENT_PASSWORD=... \
make smoke-student-invite-web
```

This runs parent login, child creation, invite creation, invite acceptance, and
child `/api/auth/me` through `web_app /api`.

## Load and chaos

Examples:
```bash
make load-auth-burst
make load-payment-access-progress
make load-live-room-burst
make chaos-payments-restart SERVICE_TOKEN=...
```

## Backup and restore

```bash
make backup-postgres
make restore-drill BACKUP_DIR=~/backups/postgres/<timestamp>
make restore-cleanup
```

## Source of truth

Operational service definitions and env wiring live in:
- [group_vars/all.yml](/Users/olegsemenov/Programming/curs/infra/ansible/group_vars/all.yml)
- [playbooks/deploy.yml](/Users/olegsemenov/Programming/curs/infra/ansible/playbooks/deploy.yml)
- [Makefile](/Users/olegsemenov/Programming/curs/infra/ansible/Makefile)
