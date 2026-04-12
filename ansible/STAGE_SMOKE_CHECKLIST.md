# Stage Smoke Checklist

## 1) Infra
- [ ] Все containers в статусе `Up` (`docker ps`).
- [ ] На сервере доступен `docker compose version`.
- [ ] Образы подтянулись с нужным tag (не `latest` для релиза).

## 2) Health endpoints
- [ ] `auth_service`: `GET /healthz` -> 200
- [ ] `users_service`: `GET /healthz` -> 200
- [ ] `course_service`: `GET /healthz` -> 200
- [ ] `attribution_service`: `GET /healthz` -> 200
- [ ] `live_class_service`: `GET /healthz` -> 200

Пример:
```bash
curl -fsS http://<stage-host>:8000/healthz
curl -fsS http://<stage-host>:8002/healthz
curl -fsS http://<stage-host>:8001/healthz
curl -fsS http://<stage-host>:8003/healthz
curl -fsS http://<stage-host>:8010/healthz
```

## 3) Auth basic flow
- [ ] Регистрация/логин тестового пользователя проходит.
- [ ] `access token` валиден, `/me` возвращает профиль.
- [ ] Refresh flow работает.

## 4) Cross-service auth/JWKS
- [ ] `users_service`, `course_service`, `attribution_service`, `live_class_service` принимают токены от `auth_service`.
- [ ] Ошибочный токен корректно отклоняется (401/403).

## 5) Course flow
- [ ] Создание/чтение курса работает.
- [ ] Ограничения ролей работают (teacher/admin vs unauthorized).

## 6) Attribution flow
- [ ] Создание referral token (admin) работает.
- [ ] Track visit endpoint принимает переход.
- [ ] Resolve discount возвращает ожидаемые данные.

## 7) Live class flow
- [ ] Создание комнаты проходит.
- [ ] Подключение teacher и student работает.
- [ ] Лимит участников соблюдается.

## 8) Data checks
- [ ] Записи появились в stage БД (`*_stage`).
- [ ] Нет ошибок миграций/схемы в логах.

## 9) Logs/Errors
- [ ] Нет массовых 5xx в логах за первые 10-15 минут.
- [ ] Нет циклических рестартов контейнеров.

## 10) Sign-off
- [ ] Smoke прошел, окружение готово для QA/нагрузочного этапа.
