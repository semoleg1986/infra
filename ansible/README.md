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
