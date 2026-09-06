# `cli` — Marzban CLI

Точка входа: корневой `marzban-cli.py` (Typer). Подкоманды — модули в
`cli/`. Для Sauce добавлены management push-scheduler'ов
(`cli/notification.py`): create/list/update/delete/test deliver — и
мониторинг аномалий (`cli/anomaly.py`): settings/configure/enable/disable/
report + CRUD вебхуков.

```bash
python marzban-cli.py --help
python marzban-cli.py notification --help
python marzban-cli.py anomaly --help
```

CLI ходит в ту же БД/логику, что и API; это не отдельный сервис.

Исключение — окно детектора аномалий: оно живёт в памяти процесса панели,
поэтому `anomaly report` и `anomaly send-now` из CLI видят пустое окно.
Настройки править из CLI можно, живую картину смотреть — только через API
или дашборд.
