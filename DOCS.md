# Sauceban — Документация по командам

Базовый формат вызова:

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ <команда> [опции]
```

Если скрипт уже установлен локально (через `install-script`), можно использовать короткий формат:

```bash
marzban <команда> [опции]
```

---

## Содержание

- [install](#install) — Установка Marzban
- [update](#update) — Обновление до последней версии
- [uninstall](#uninstall) — Удаление Marzban
- [up](#up) — Запуск сервисов
- [down](#down) — Остановка сервисов
- [restart](#restart) — Перезапуск сервисов
- [status](#status) — Проверка статуса
- [logs](#logs) — Просмотр логов
- [cli](#cli) — Marzban CLI
- [backup](#backup) — Ручной бэкап
- [backup-service](#backup-service) — Автобэкап в Telegram
- [core-update](#core-update) — Обновление Xray-core
- [migrate](#migrate) — Миграция между источниками (image / build)
- [tblocker](#tblocker) — Установка Xray Torrent Blocker
- [tblocker-config](#tblocker-config) — Управление вебхуком tblocker
- [log-clean](#log-clean) — Очистка access-лога по расписанию
- [edit](#edit) — Редактирование docker-compose.yml
- [edit-env](#edit-env) — Редактирование .env
- [install-script](#install-script) — Установка скрипта marzban

---

## install

Установка Marzban с нуля. Автоматически установит Docker, зависимости, создаст конфигурацию и запустит контейнеры.

**Базовая установка (SQLite, latest):**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ install
```

**Установка с MariaDB:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ install --database mariadb
```

**Установка с MySQL и заданным паролем БД:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ install --database mysql --db-password MySecurePass123
```

**Установка с указанием версии:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ install --version v0.5.2
```

**Установка dev-версии:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ install --dev
```

**Полностью автоматическая установка (для автоматизации):**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ install \
  --database mariadb \
  --db-password MySecurePass123 \
  --sudo-username admin \
  --sudo-password AdminPass456
```

| Опция | Описание |
|---|---|
| `--database <sqlite\|mariadb\|mysql>` | Тип базы данных (по умолчанию: `sqlite`) |
| `--db-password <пароль>` | Пароль для пользователя БД (если не указан — сгенерируется автоматически) |
| `--sudo-username <имя>` | Имя суперпользователя Marzban |
| `--sudo-password <пароль>` | Пароль суперпользователя Marzban |
| `--version <vX.Y.Z>` | Конкретная версия для установки |
| `--dev` | Установить dev-версию (нельзя использовать вместе с `--version`) |

---

## update

Обновление Marzban до последней версии. Автоматически подтянет новый образ или пересоберёт из исходников (в зависимости от типа установки), затем перезапустит контейнеры.

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ update
```

Или через локальный скрипт:

```bash
marzban update
```

---

## uninstall

Удаление Marzban. Скрипт спросит подтверждение и предложит удалить данные.

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ uninstall
```

> **Внимание:** Команда интерактивная — потребует подтверждения (y/n).

---

## up

Запуск остановленных контейнеров Marzban. После запуска по умолчанию показывает логи.

```bash
marzban up
```

**Запустить без вывода логов:**

```bash
marzban up -n
```

| Опция | Описание |
|---|---|
| `-n`, `--no-logs` | Не показывать логи после запуска |

---

## down

Остановка всех контейнеров Marzban.

```bash
marzban down
```

---

## restart

Перезапуск контейнеров (down + up). По умолчанию показывает логи после перезапуска.

```bash
marzban restart
```

**Перезапустить без вывода логов:**

```bash
marzban restart -n
```

| Опция | Описание |
|---|---|
| `-n`, `--no-logs` | Не показывать логи после перезапуска |

---

## status

Показать текущее состояние всех сервисов Marzban (запущены / остановлены).

```bash
marzban status
```

---

## logs

Просмотр логов контейнеров Marzban. По умолчанию работает в режиме follow (как `tail -f`).

```bash
marzban logs
```

**Показать логи без follow (только текущие):**

```bash
marzban logs -n
```

| Опция | Описание |
|---|---|
| `-n`, `--no-follow` | Показать логи однократно, без отслеживания |

---

## cli

Вызов встроенного Marzban CLI внутри контейнера. Все аргументы передаются как есть.

```bash
marzban cli admin create --sudo
```

---

## backup

Ручной запуск бэкапа. Создаёт архив с БД, `.env`, `docker-compose.yml` и данными. Если настроен backup-service — отправит в Telegram.

```bash
marzban backup
```

---

## backup-service

Интерактивная настройка автоматического бэкапа в Telegram. Создаёт cron-задачу для периодической отправки бэкапов.

```bash
marzban backup-service
```

Скрипт запросит:
1. **Telegram Bot API Key** — токен бота
2. **Telegram Chat ID** — ID чата для отправки
3. **Интервал** — частота бэкапов (1–24 часа)

Если сервис уже настроен, предложит перенастроить или удалить.

---

## core-update

Обновление или смена версии Xray-core. Без аргументов показывает интерактивное меню. С аргументами — работает полностью без интерактива.

**Интерактивный режим (меню выбора версии):**

```bash
marzban core-update
```

**Установить конкретную версию (без интерактива):**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ core-update --version v24.12.18
```

**Установить последнюю версию автоматически (без интерактива):**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ core-update --latest
```

| Опция | Описание |
|---|---|
| `--version <vX.Y.Z>` | Установить конкретную версию Xray-core |
| `--latest` | Автоматически определить и установить последнюю версию |
| без опций | Интерактивное меню выбора версии |

---

## migrate

Миграция Marzban между разными источниками (Docker Hub образ или сборка из исходников). Данные и база данных сохраняются.

**Миграция на образ Sauceban:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ migrate --image v2as/sauceban:latest -y
```

**Миграция на оригинальный Marzban:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ migrate --image gozargah/marzban:latest -y
```

**Миграция на конкретную версию:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ migrate --image gozargah/marzban:v0.5.2 -y
```

**Сборка из исходников Sauceban:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ migrate --build sauceban -y
```

**Сборка из исходников Gozargah (ветка dev):**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ migrate --build gozargah --branch dev -y
```

| Опция | Описание |
|---|---|
| `--image <image:tag>` | Использовать готовый Docker-образ |
| `--build <sauceban\|gozargah>` | Собрать из исходников |
| `--branch <имя>` | Ветка для сборки (по умолчанию: `master`) |
| `-y`, `--yes` | Пропустить подтверждение (для автоматизации) |

---

## tblocker

Установка и настройка Xray Torrent Blocker для Marzban. Автоматически настроит xray-конфиг, добавит правила маршрутизации, установит logrotate и запустит сервис.

**Базовая установка (iptables, 10 минут блокировки):**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ tblocker
```

**С nftables и длительностью 30 минут:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ tblocker --firewall nft --duration 30
```

**Полная установка с вебхуком (для автоматизации):**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ tblocker \
  --firewall iptables \
  --duration 10 \
  --webhook-url "https://your-webhook-url.com/endpoint" \
  --webhook-token "your-secret-token"
```

| Опция | Описание |
|---|---|
| `--firewall <iptables\|nft>` | Какой файрвол использовать (по умолчанию: `iptables`) |
| `--duration <минуты>` | Длительность блокировки IP в минутах (по умолчанию: `10`) |
| `--webhook-url <URL>` | URL вебхука (автоматически включает `SendWebhook: true`) |
| `--webhook-token <TOKEN>` | Bearer-токен для заголовка Authorization |

При указании `--webhook-url` в `/opt/tblocker/config.yaml` запишется:

```yaml
SendWebhook: true
WebhookURL: "https://your-webhook-url.com/endpoint"
WebhookTemplate: '{"username":"%s","ip":"%s","server":"%s","action":"%s","duration":%d,"timestamp":"%s"}'
WebhookHeaders:
  Authorization: "Bearer your-secret-token"
  Content-Type: "application/json"
```

---

## tblocker-config

Управление конфигурацией вебхука tblocker после установки. Позволяет менять URL, токен, включать/выключать вебхук без ручного редактирования конфига.

**Установить URL вебхука (автоматически включает SendWebhook):**

```bash
marzban tblocker-config set-webhook-url "https://your-webhook-url.com/endpoint"
```

**Установить или заменить Bearer-токен:**

```bash
marzban tblocker-config set-webhook-token "your-new-secret-token"
```

**Включить вебхук:**

```bash
marzban tblocker-config enable-webhook
```

**Выключить вебхук:**

```bash
marzban tblocker-config disable-webhook
```

**Посмотреть текущий конфиг:**

```bash
marzban tblocker-config show
```

**Получить значение конкретного параметра:**

```bash
marzban tblocker-config get WebhookURL
```

| Подкоманда | Описание |
|---|---|
| `set-webhook-url <URL>` | Установить WebhookURL и включить SendWebhook |
| `set-webhook-token <TOKEN>` | Установить/заменить Bearer-токен в заголовке Authorization |
| `enable-webhook` | Включить отправку вебхуков (`SendWebhook: true`) |
| `disable-webhook` | Выключить отправку вебхуков (`SendWebhook: false`) |
| `show` | Вывести полный конфиг `/opt/tblocker/config.yaml` |
| `get <KEY>` | Получить значение конкретного ключа |

> **Важно:** После изменений через `tblocker-config` необходимо перезапустить сервис:
> ```bash
> systemctl restart tblocker
> ```

---

## log-clean

Управление очисткой access-лога (`/var/lib/marzban/logs/access.log`), который использует tblocker. Позволяет настроить автоматическую очистку по cron, чтобы лог не переполнял диск.

**Настроить очистку каждые 6 часов:**

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ log-clean --interval 6
```

**Очистка раз в сутки (в полночь):**

```bash
marzban log-clean --interval 24
```

**Очистить лог прямо сейчас (разовая операция):**

```bash
marzban log-clean --now
```

**Посмотреть текущее расписание и размер лога:**

```bash
marzban log-clean --status
```

**Изменить интервал (просто вызвать с новым значением — старый cron заменится):**

```bash
marzban log-clean --interval 12
```

**Отключить автоматическую очистку:**

```bash
marzban log-clean --disable
```

| Опция | Описание |
|---|---|
| `--interval <часы>` | Настроить очистку каждые N часов (1–24). Повторный вызов заменяет предыдущее расписание |
| `--now` | Очистить лог немедленно (одноразово, без cron) |
| `--status` | Показать текущее расписание очистки и размер лога |
| `--disable` | Удалить cron-задачу очистки |

> **Примечание:** `--interval` использует `truncate -s 0`, что обнуляет файл без удаления — безопасно для процессов, которые держат файл открытым (tblocker, xray).

---

## edit

Открыть `docker-compose.yml` в текстовом редакторе (nano или vi).

```bash
marzban edit
```

---

## edit-env

Открыть файл `.env` в текстовом редакторе (nano или vi).

```bash
marzban edit-env
```

---

## install-script

Установить скрипт `marzban` в `/usr/local/bin/`, чтобы можно было вызывать команды напрямую через `marzban <команда>` вместо полной строки с `curl`.

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/V2as/Sauceban/master/sauceme.sh)" @ install-script
```

После этого все команды доступны в коротком формате:

```bash
marzban status
marzban restart -n
marzban tblocker --firewall nft --duration 15
```

---

## help

Вывести справку по всем доступным командам.

```bash
marzban help
```

---

## Директории

| Путь | Описание |
|---|---|
| `/opt/marzban/` | Директория приложения (docker-compose.yml, .env) |
| `/var/lib/marzban/` | Данные Marzban (БД, конфиги xray, логи) |
| `/opt/tblocker/config.yaml` | Конфигурация Torrent Blocker |
| `/var/lib/marzban/logs/` | Логи xray (access.log, error.log) |

## Полезные команды для диагностики

```bash
# Статус tblocker
systemctl status tblocker

# Логи tblocker в реальном времени
journalctl -u tblocker -f

# Логи Marzban в реальном времени
marzban logs

# Перезапуск tblocker после изменения конфига
systemctl restart tblocker
```
