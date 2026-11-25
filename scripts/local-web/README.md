# Feishin Local Web scripts

Скрипты для Windows-варианта Feishin: установка зависимостей без Electron lifecycle, сборка web, регистрация Caddy как службы, удаление этой службы и ручная проверка Navidrome/Caddy.

## Размещение

Распакуй содержимое архива в корень репозитория `C:\MY\Projects\Feishin`, сохранив структуру `scripts\local-web`.

Рекомендуемое расположение Caddy:

```text
Feishin\
  tools\
    caddy\
      caddy.exe
```

Скрипты также ищут `caddy.exe` в корне проекта для совместимости со старой конфигурацией.

Добавь в `.gitignore`:

```gitignore
/tools/caddy/caddy.exe
/Caddyfile
/services.json
/logs/
```

## Сборка браузерной версии

Из корня репозитория:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\local-web\Build-Web.ps1
```

Скрипт:

1. Проверяет версию pnpm из `package.json`.
2. Выполняет `pnpm install --frozen-lockfile --ignore-scripts`, поэтому `postinstall` Feishin (`install-electron && electron-builder install-app-deps`) не запускается.
3. Выполняет `pnpm run build:web`.
4. Создаёт `out\web\settings.js` из `settings.js.template`, как это делается в Docker-сценарии.

Повторяй этот скрипт после изменений исходников. Не запускай для веб-сборки просто `pnpm run build:web` на чистом `node_modules`: pnpm может сначала выполнить обычную установку и запустить Electron postinstall.

Результат: `out\web`. При уже работающем Caddy обычно достаточно обновить страницу через Ctrl+F5.

## Установка служб

Открой PowerShell от имени администратора:

```powershell
.\scripts\local-web\Install-Services.ps1
```

Скрипт:

- проверяет Caddyfile;
- создаёт его, если файла ещё нет;
- регистрирует Caddy как службу `CaddyFeishin` с автоматическим запуском;
- включает автоматический запуск уже существующей службы Navidrome, но не устанавливает и не удаляет Navidrome;
- настраивает восстановление службы Caddy после аварийного завершения.

Feishin будет доступен по адресу `http://127.0.0.1:9181`.

## Ручная проверка и восстановление

Запускай только по необходимости, из PowerShell от имени администратора:

```powershell
.\scripts\local-web\Check-Services.ps1
```

Скрипт однократно проверяет состояние служб и HTTP-адреса. Остановленную службу запускает; если служба запущена, но endpoint не отвечает, перезапускает её. Никакой фоновой задачи или периодического мониторинга не создаётся. Результат записывается в `logs\service-check.log`.

## Удаление службы Caddy

Из PowerShell от имени администратора:

```powershell
.\scripts\local-web\Remove-Services.ps1
```

Удаляет только службу `CaddyFeishin`. Не удаляет Navidrome, `caddy.exe`, Caddyfile, логи или собранные файлы.

## Настройка имён служб и адресов

При первой установке создаётся `services.json` в корне проекта, если его ещё нет. Значения по умолчанию:

```json
{
  "Navidrome": {
    "ServiceName": "Navidrome",
    "HealthUrl": "http://127.0.0.1:4533/ping"
  },
  "Caddy": {
    "ServiceName": "CaddyFeishin",
    "HealthUrl": "http://127.0.0.1:9181/"
  }
}
```

Измени `ServiceName` или `HealthUrl`, если служба Navidrome у тебя называется иначе или использует другой порт.
