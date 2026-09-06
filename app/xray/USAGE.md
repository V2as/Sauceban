# `app/xray` — ядро и ноды

Обёртка над процессом Xray и удалёнными нодами. gRPC-схемы — пакет
`xray_api/` (генерированный, не править руками без нужды).

| Файл | Назначение |
|---|---|
| `core.py` | локальный процесс Xray |
| `config.py` | разбор/сборка конфига из `XRAY_JSON` + inbound'ов БД |
| `node.py` | Marzban Node (удалённые ноды) |
| `operations.py` | операции над пользователями в ядре |

Конфиг панели на диске — корневой `xray_config.json` (путь переопределяется
`XRAY_JSON`). Изменения inbound'ов в БД должны попадать в running config
через этот пакет, а не правкой JSON вручную в проде.

`config.py` принудительно выставляет `policy.levels."0"`:
`statsUserUplink`/`statsUserDownlink` (учёт трафика) и `statsUserOnline`
(online-IP для детектора аномалий). Ядра, которые не знают `statsUserOnline`,
ключ игнорируют. Сами online-IP читаются RPC-обёртками из
`xray_api/online.py` (`Stats.get_users_online_stats` /
`get_user_online_ips`) — их нет в сгенерированных стабах, см. `MEMORY.md`.
