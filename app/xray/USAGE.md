# `app/xray` — ядро и ноды

Обёртка над процессом Xray и удалёнными нодами. gRPC-схемы — пакет
`xray_api/` (генерированный, не править руками без нужды).

| Файл | Назначение |
|---|---|
| `core.py` | локальный процесс Xray |
| `config.py` | разбор/сборка конфига из `XRAY_JSON` + inbound'ов БД |
| `goenv.py` | **Sauce:** `GOMEMLIMIT` для процесса ядра из файла `XRAY_GO_ENV_FILE` |
| `node.py` | Marzban Node (удалённые ноды) |
| `operations.py` | операции над пользователями в ядре |

Лимит памяти ядра — контракт из трёх частей: `goenv.read_memory_limit()`
читает `XRAY_GO_ENV_FILE` (строка `GOMEMLIMIT=<размер>`), `core.start()`
кладёт значение в окружение дочернего процесса и запоминает применённое в
`core.memory_limit`, а `core_health_check` перезапускает ядро, когда файл и
работающий процесс разошлись. Значения, которых Go-рантайм не понимает
(`1G`, `1GB`), отбрасываются с предупреждением: ядро с таким `GOMEMLIMIT` не
стартует вообще. Ноды сюда не входят — у них свой процесс.

Конфиг панели на диске — корневой `xray_config.json` (путь переопределяется
`XRAY_JSON`). Изменения inbound'ов в БД должны попадать в running config
через этот пакет, а не правкой JSON вручную в проде.

`config.py` принудительно выставляет `policy.levels."0"`:
`statsUserUplink`/`statsUserDownlink` (учёт трафика) и `statsUserOnline`
(online-IP для детектора аномалий и лимитов канала). Ядра, которые не знают `statsUserOnline`,
ключ игнорируют. Сами online-IP читаются RPC-обёртками из
`xray_api/online.py` (`Stats.get_users_online_stats`,
`get_all_online_users`, `get_user_online_ips`) — их нет в сгенерированных
стабах. Каждая появилась в своей версии ядра (`v26.4.13` / `v25.12.1` /
`v25.2.18`), отсюда лестница фолбэков в `app/jobs/detect_anomalies.py` и
`app/jobs/sync_blacklist.py`; подробнее — `MEMORY.md`.

`get_all_online_users` / `get_users_online_stats` отдают **голый email**:
ядро возвращает имя счётчика (`user>>>EMAIL>>>online`), обёртка его
разбирает. Сравнивать с `f"{user.id}.{user.username}"` можно напрямую.
