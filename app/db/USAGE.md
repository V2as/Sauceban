# `app/db` — доступ к БД

SQLAlchemy 2 + Alembic. URL из `SQLALCHEMY_DATABASE_URL` (SQLite / MySQL /
Postgres). Схему меняем только миграциями.

| Файл | Назначение |
|---|---|
| `base.py` | engine, Session, `GetDB` |
| `models.py` | ORM-таблицы (users, admins, nodes, …, `notification_schedulers`, `anomaly_settings`, `anomaly_schedulers`, `blacklist_users`, `bandwidth_settings`) |
| `crud.py` | все запросы к БД (~1.5k строк) — правки логики выборки сюда |
| `migrations/` | Alembic versions; конфиг — корневой `alembic.ini` |

```bash
alembic -c alembic.ini upgrade head
alembic -c alembic.ini revision --autogenerate -m "..."
```

Не пишите диалект-специфичный SQL без нужды: одна кодовая база на три СУБД.
Новая таблица push-scheduler'ов — миграция `f1a2b3c4d5e6` (идемпотентный
`upgrade`); таблицы мониторинга аномалий — `b7c8d9e0f1a2`, так же
идемпотентно.

`anomaly_settings` — строка-одиночка: `get_anomaly_settings()` создаёт её с
дефолтами при первом обращении, отдельного «сидинга» нет.

`blacklist_users` (миграция `c3d4e5f6a7b8`, тоже идемпотентная) — лимит
канала на пользователя, не более одной строки на `user_id`. Удаление
пользователя снимает лимит: `ON DELETE CASCADE` на уровне БД плюс
`cascade="all, delete-orphan"` на связи `User.blacklist_entry` — без него
удаление через ORM оставляло бы висячую строку на SQLite.

Миграция `d4e5f6a7b8c9` (тоже идемпотентная, только `ADD COLUMN` в свои же
таблицы) добавляет авто-замедление: `blacklist_users.source` (`manual` /
`anomaly`) и `expires_at`, плюс `throttle_*` в `anomaly_settings`. Правило
владения — в CRUD: `update_blacklist_entry` переводит запись в `manual` и
снимает срок, `upsert_anomaly_throttle` не трогает чужую (`manual`) запись,
`expire_anomaly_throttles` удаляет истёкшие. `get_active_blacklist` отдаёт
`expires_at` вызывающему, а не фильтрует сама: так снятие истёкших стоит
лишний запрос только когда есть что снимать.

`get_users_to_review` / `get_on_hold_users_to_review` — выборки для джобы
статусов: условия, которые она раньше проверяла в Python, перечислены в
`WHERE`. Меняете логику `review_users.py` — меняйте и фильтр, иначе джоба
перестанет видеть пользователей, на которых должна реагировать.

`bandwidth_settings` (миграция `e5f6a7b8c9d0`, идемпотентная) — строка-одиночка
с общим лимитом канала: `global_enabled` и `global_mbps`.
`get_bandwidth_settings()` создаёт её с дефолтами при первом обращении, как у
`anomaly_settings`. В переменные окружения это не вынесено намеренно:
переключатель живёт в дашборде, а значит должен переживать рестарт без
редеплоя.
