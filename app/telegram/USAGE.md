# `app/telegram` — Telegram-бот панели

Опциональный бот на `pyTelegramBotAPI`. Включается переменными из
`.env.example` (`TELEGRAM_API_TOKEN` и связанные). Хендлеры — в
`handlers/`, утилиты — `utils/`.

Не путать с push-метриками: бот — операторский UI, push — HTTP webhooks
на внешний мониторинг (`USAGE-PUSH.md`).
