# `app/routers` — HTTP API

Все роуты монтируются в `api_router` → `app.include_router` в
`app/__init__.py`. Префикс админки обычно `/api/...`; подписки — отдельно
(`subscription.py`, путь из `XRAY_SUBSCRIPTION_PATH`).

| Файл | Зона |
|---|---|
| `admin.py` | админы, токен |
| `user.py` / `user_template.py` | пользователи и шаблоны |
| `node.py` / `core.py` / `system.py` | ноды, ядро Xray, система |
| `subscription.py` | выдача клиентских конфигов |
| `notification.py` | event-webhooks **и** CRUD push-scheduler'ов |
| `anomaly.py` | настройки детектора аномалий, его вебхуки, live-отчёт |
| `home.py` | корень / редиректы |

Новый эндпоинт: роутер → pydantic в `app/models` → crud в `app/db/crud.py`.
Push management API подробно — корневой `USAGE-ADD-PUSH.md`, API аномалий —
`USAGE-ANOMALY.md`.

`/api/anomaly/*` требует sudo-админа. `GET /report` — read-only: не двигает
счётчики подряд-срабатываний и cooldown'ы, поэтому его можно опрашивать не
влияя на то, что уйдёт в вебхуки.
