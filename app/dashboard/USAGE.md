# `app/dashboard` — SPA админки

React + Chakra UI + Vite + TypeScript. Исходники — `src/`, в образ и git
попадает собранный `build/` (не редактировать вручную).

```bash
cd app/dashboard
npm ci
npm run dev      # :3000, API из VITE_BASE_API / proxy
npm run build -- --outDir build --assetsDir statics    # → build/statics
```

Флаги `--outDir/--assetsDir` обязательны: без них vite кладёт сборку в
`dist/assets`, а панель раздаёт `build/` и монтирует `/statics/`
(`app/dashboard/__init__.py`). Оттуда же копируется `build/404.html` —
это копия `index.html`.

Новый раздел UI: страница/компонент в `src/` → API-клиент (ofetch) на
`/api/...` → при необходимости эндпоинт в `app/routers`. Push-scheduler UI
ходит в `/api/notification` (см. `USAGE-ADD-PUSH.md`), мониторинг аномалий —
в `/api/anomaly` (`AnomalyContext.tsx` + `AnomalySettingsModal.tsx`,
см. `USAGE-ANOMALY.md`).

Строки локализованы плоскими ключами с точками
(`"anomaly.severity.high"`), а не вложенными объектами — в
`public/statics/locales/*.json` держите тот же стиль. Полностью переведены
`en`/`ru`; `fa`/`zh` получают заголовок, остальное падает в английский
fallback.

`node_modules/` в git нет (локальный `.gitignore`). Node в CI образа — 20.
