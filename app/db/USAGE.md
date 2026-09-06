# `app/db` — доступ к БД

SQLAlchemy 2 + Alembic. URL из `SQLALCHEMY_DATABASE_URL` (SQLite / MySQL /
Postgres). Схему меняем только миграциями.

| Файл | Назначение |
|---|---|
| `base.py` | engine, Session, `GetDB` |
| `models.py` | ORM-таблицы (users, admins, nodes, …, `notification_schedulers`, `anomaly_settings`, `anomaly_schedulers`) |
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
