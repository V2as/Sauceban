# `app/subscription` — клиентские конфиги

Сборка подписок и deep-link'ов из inbound'ов пользователя.

| Файл | Формат |
|---|---|
| `v2ray.py` | vless/vmess/trojan ссылки + JSON |
| `clash.py` / `singbox.py` / `outline.py` | соответствующие клиенты |
| `share.py` | общие хелперы, статусы, IP |
| `funcs.py` | утилиты сборки |

Шаблоны ответов — `app/templates/{clash,singbox,v2ray}/`.

**Sauce:** `xhttpSettings.extra` обязан пробрасываться в клиент (query
`extra` и вложенный JSON). Иначе XHTTP-опции контракта (`uplinkHTTPMethod`
и др.) остаются только на сервере, и клиент не коннектится. См. `MEMORY.md`.
