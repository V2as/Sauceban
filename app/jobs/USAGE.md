# `app/jobs` — фоновые задачи

APScheduler (`BackgroundScheduler` в `app/__init__.py`), timezone UTC.
Импорт пакета на старте регистрирует джобы.

| Файл | Задача |
|---|---|
| `0_xray_core.py` | старт/надзор процесса Xray |
| `record_usages.py` | учёт трафика |
| `review_users.py` | статусы пользователей |
| `remove_expired_users.py` / `reset_user_data_usage.py` | истечение / сброс |
| `send_notifications.py` | event-webhooks (`WEBHOOK_ADDRESS`) |
| `send_push_metrics.py` | **Sauce:** периодический POST метрик по scheduler'ам из БД |
| `detect_anomalies.py` | **Sauce:** семплер online-IP + отчёты об аномалиях на вебхуки |
| `sync_blacklist.py` | **Sauce:** сверка лимитов канала (`blacklist_users` → `tc`, `bandwidth_settings` → `nft`) |

Push-джоба аддитивна: нет строк в `notification_schedulers` → ничего не
бежит. Reconciler синхронизирует interval/enable без рестарта. Сборщик —
`app/utils/metrics.py`. Контракт — `USAGE-PUSH.md`.

Джоба аномалий: `sync_anomaly_monitor` (каждые
`JOB_SYNC_ANOMALY_MONITOR_INTERVAL`) заводит/снимает семплер `run_sample` по
флагу `anomaly_settings.is_enabled`; выключение сбрасывает окно и очереди.
Движок детекции — `app/utils/anomaly.py` (состояние в памяти процесса),
доставка переиспользует `deliver()` из `send_push_metrics` с другим
`User-Agent`. При `throttle_enabled` тик ещё и вешает лимит нарушителю
(`_apply_throttles` → `crud.upsert_anomaly_throttle` → `request_sync()`
чёрного списка): своей инфраструктуры для ограничения канала у детектора
нет, он пишет запись со сроком в `blacklist_users`. Контракт —
`USAGE-ANOMALY.md`.

Джоба чёрного списка: `run_sync` (каждые `JOB_SYNC_BLACKLIST_INTERVAL`)
берёт включённые записи, спрашивает у ядра адреса этих пользователей и
отдаёт пары «адрес → лимит» шейперу (`app/utils/shaper.py`). Мутации через
API дергают `request_sync()` — отложенную на секунду разовую джобу, чтобы
gRPC и `tc` не висели в HTTP-запросе. Пустой список — правила снимаются,
тик стоит один SELECT. Здесь же снимаются истёкшие авто-замедления — то
есть они истекают и при выключенном мониторинге аномалий. Контракт —
`USAGE-BLACKLIST.md`.

Тот же тик сверяет общий лимит (`bandwidth_settings` → `app/utils/global_limiter.py`):
адреса для него не нужны — бакеты держит ядро, — поэтому это лишний SELECT и
сравнение кортежа, а `nft` вызывается только когда настройка изменилась (плюс
раз в минуту проверка, что правила не снёс чужой firewall). Настройки читаются
в своём `try`: непромигрированная БД не должна ломать сверку лимитов на
пользователей.

`review_users.py` бежит каждые `JOB_REVIEW_USERS_INTERVAL` (по умолчанию 10 с)
и берёт из БД только тех, с кем тик что-то сделает: исчерпавших лимит или
срок, а при включённых вебхуках — ещё и подошедших к порогам напоминаний
(`crud.get_users_to_review` / `get_on_hold_users_to_review`). Выборку «все
активные» сюда не возвращать: на панели с десятками тысяч аккаунтов это
минуты запросов и пик памяти каждые десять секунд (см. `MEMORY.md`).

Не предлагайте несколько uvicorn-workers: scheduler один на процесс.
