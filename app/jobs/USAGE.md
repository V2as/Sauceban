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

Push-джоба аддитивна: нет строк в `notification_schedulers` → ничего не
бежит. Reconciler синхронизирует interval/enable без рестарта. Сборщик —
`app/utils/metrics.py`. Контракт — `USAGE-PUSH.md`.

Джоба аномалий: `sync_anomaly_monitor` (каждые
`JOB_SYNC_ANOMALY_MONITOR_INTERVAL`) заводит/снимает семплер `run_sample` по
флагу `anomaly_settings.is_enabled`; выключение сбрасывает окно и очереди.
Движок детекции — `app/utils/anomaly.py` (состояние в памяти процесса),
доставка переиспользует `deliver()` из `send_push_metrics` с другим
`User-Agent`. Контракт — `USAGE-ANOMALY.md`.

Не предлагайте несколько uvicorn-workers: scheduler один на процесс.
