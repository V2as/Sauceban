# `app/models` — pydantic-схемы API

Не путать с ORM (`app/db/models.py`). Здесь request/response для FastAPI.

| Файл | Зона |
|---|---|
| `user.py` / `user_template.py` / `admin.py` | пользователи, шаблоны, админы |
| `proxy.py` / `node.py` / `core.py` / `system.py` | прокси, ноды, ядро |
| `notification_scheduler.py` | **Sauce:** схемы push-scheduler'ов и payload метрик |
| `anomaly.py` | **Sauce:** настройки детектора, его вебхуки, payload отчёта |
| `blacklist.py` | **Sauce:** записи чёрного списка и статус применения лимитов |

Валидация интервала scheduler'а завязана на `PUSH_SCHEDULER_MIN_INTERVAL`
из `config.py`, интервалов аномалий — на `ANOMALY_MIN_SAMPLE_INTERVAL`,
потолок лимита канала — на `BLACKLIST_MAX_MBPS` (в том числе для
`throttle_mbps` в настройках аномалий: автоматика не может выставить лимит,
который оператор выставить не вправе).

Шкала severity (`low/medium/high/critical`) — часть контракта приёмника:
пороги детектора крутит оператор, шкала остаётся сравнимой между панелями.
