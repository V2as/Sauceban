# AGENTS.md

Sauceban — форк [Marzban](https://github.com/gozargah/marzban) с аддонами
Sauce (push-метрики, Hysteria 2, xhttp `extra`, кастомный `sauceme.sh`).
Версия панели: `__version__` в `app/__init__.py` (сейчас `0.8.6`).

Upstream README / DOCS.md — про Marzban вообще. Здесь — только то, что нужно
агенту до начала работы. Карта модулей — таблица ниже; решения и подводные
камни — в `MEMORY.md`.

## Стек

Python 3.12 (образ), FastAPI, SQLAlchemy 2 + Alembic, APScheduler
(BackgroundScheduler), Xray через gRPC (`xray_api/`), React + Chakra + Vite
(дашборд), опционально Telegram-бот (`pyTelegramBotAPI`). БД по умолчанию
SQLite; в проде обычно MySQL/MariaDB или Postgres через
`SQLALCHEMY_DATABASE_URL`.

## Команды

```bash
python main.py                                 # локальный запуск (см. UVICORN_*)
alembic -c alembic.ini upgrade head            # миграции
alembic -c alembic.ini revision --autogenerate -m "..."
cd app/dashboard && npm ci && npm run build     # SPA → app/dashboard/build
docker compose up -d --build                   # образ панели
python marzban-cli.py --help                   # CLI
```

Линтеров/pytest-набора в корне нет. Не добавляйте их без запроса и не
переформатируйте файлы целиком.

## Где искать документацию

| Область | Документ |
|---|---|
| Решения, причины, подводные камни | `MEMORY.md` |
| БД, CRUD, миграции | `app/db/USAGE.md` |
| HTTP API (роутеры) | `app/routers/USAGE.md` |
| Фоновые джобы | `app/jobs/USAGE.md` |
| Подписки / клиентские конфиги | `app/subscription/USAGE.md` |
| Xray-процесс и ноды | `app/xray/USAGE.md` |
| Pydantic-модели API | `app/models/USAGE.md` |
| Дашборд (React) | `app/dashboard/USAGE.md` |
| Telegram-бот | `app/telegram/USAGE.md` |
| CLI | `cli/USAGE.md` |
| Push-метрики (контракт для приёмника) | `USAGE-PUSH.md` |
| Push-метрики (management API) | `USAGE-ADD-PUSH.md` |
| Мониторинг аномалий трафика (детектор + push) | `USAGE-ANOMALY.md` |
| Команды `sauceme.sh` / `marzban` | `DOCS.md` |

Меняете поведение модуля — обновите его `USAGE.md` (и при необходимости
`MEMORY.md`) в том же коммите.

## Жёсткие соглашения

**Один воркер uvicorn.** В `main.py` явно: multi-workers не реализован для
APScheduler и Xray. Не поднимайте `--workers N` и не предлагайте это в
compose.

**`app/dashboard/build` в git.** Так устроен деплой образа. Правки — в
`app/dashboard/src/`, затем `npm run build`. `build/` руками не редактировать.

**Секреты.** `.env` в git не попадает (есть `.env.example`). Значения в код и
примеры не подставляйте — только имена переменных.

**Ветки и CI.** Рабочая ветка — `main`. Docker-образ на Docker Hub собирается
workflow `build.yml` с ветки **`master`** и тегов `v*.*.*` — push в `main`
образ сам не публикует. `build-dev.yml` — ветка `dev`.
