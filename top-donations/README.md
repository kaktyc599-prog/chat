# Благодарности за донаты DonationAlerts для OBS

Бегущая благодарность «Огромное спасибо — {имя} за {сумма}». Плашка по очереди показывает
всех донатеров (а не только топ‑5), после полного круга делает паузу, примерно 40 секунд,
и начинается заново. Работает в OBS на Windows и macOS.

## Файлы

| Файл | Назначение |
|---|---|
| `top-donations.html` | Сам оверлей благодарности для OBS |
| `top-donations-data.js` | Данные топа (обновляются автоматически) |
| `top-donations-config.json` | Токен и настройки обновления |
| `top-donations-update.ps1` | Обновление из DonationAlerts на Windows |
| `start-top-donations.bat` | Запуск обновления на Windows двойным кликом |
| `top-donations-update.py` | Обновление из DonationAlerts на macOS / Linux |
| `start-top-donations.command` | Запуск обновления на macOS двойным кликом |

## Добавить в OBS

1. Добавьте источник **Browser** / **Браузер**.
2. Включите **Local file** / **Локальный файл**.
3. Выберите `top-donations/top-donations.html`.
4. Размер источника примерно **360 × 62**.
5. Фон прозрачный, дополнительные настройки не нужны.

На macOS путь будет вида:

```text
/Users/ВАШ_ПОЛЬЗОВАТЕЛЬ/Desktop/Splicer_Irl/top-donations/top-donations.html
```

## Подключить DonationAlerts

1. Откройте `top-donations-config.json`.
2. Вставьте токен в `secretToken`:
   - DonationAlerts → настройки → основной раздел, или
   - параметр `token=` из ссылки любого виджета.
3. Запустите обновление:
   - **Windows:** двойной клик по `start-top-donations.bat`.
   - **macOS:** двойной клик по `start-top-donations.command`.
4. Окно с обновлением не закрывайте во время стрима.
5. Оверлей сам перечитывает `top-donations-data.js` каждые 30 секунд.

### macOS

Если двойной клик по `start-top-donations.command` ничего не делает, один раз выполните в Терминале:

```bash
cd ~/Desktop/Splicer_Irl/top-donations
chmod +x start-top-donations.command
./start-top-donations.command
```

Если Python 3 не установлен:

```bash
xcode-select --install
# или
brew install python
```

Обновить один раз без постоянного цикла:

```bash
cd ~/Desktop/Splicer_Irl/top-donations
python3 top-donations-update.py --once
```

Проверить подсчёт без интернета:

```bash
python3 top-donations-update.py --self-test
```

### Windows

Если `.bat` не запускается, откройте PowerShell в папке `top-donations` и выполните:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\top-donations-update.ps1
```

Один раз:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\top-donations-update.ps1 -Once
```

## Настройки

В `top-donations-config.json`:

| Поле | Значение |
|---|---|
| `secretToken` | Токен DonationAlerts |
| `topCount` | `0` (по умолчанию) — показывать всех донатеров; число больше 0 — только первые N мест |
| `periodDays` | Период в днях; `0` — все доступные донаты |
| `refreshSeconds` | Как часто обновлять данные, минимум 30 |
| `displayCurrency` | Валюта, если DonationAlerts не отдал основную |
| `skipAnonymous` | `true` — скрыть анонимов; `false` — собрать их в строку «Аноним» |

Текст фразы (`prefix`, `tail`), время показа каждого донатера (`showSeconds`)
и пауза после списка (`pauseSeconds`) настраиваются в `top-donations.html`
в блоке `CONFIG`.

## Вручную

Можно вообще не запускать обновление, а отредактировать `top-donations-data.js`:

```js
window.TOP_DONATIONS = [
    { username: "Имя", amount: 5000, currency: "RUB", donations: 3 }
];
window.TOP_DONATIONS_IS_DEMO = false;
```

## Важно

- Официального публичного API «топ донатеров» у DonationAlerts нет. Скрипт открывает страницу виджета `lastdonations` с вашим `secretToken` и сам суммирует донаты по никам.
- Виджет отдаёт до **100 последних событий**. Для большинства стримеров этого достаточно; если донатов больше, топ считается по последним 100.
- Используется внутренний механизм DonationAlerts, а не OAuth. Он может перестать работать, если DonationAlerts изменит виджет.
- Не публикуйте `top-donations-config.json` с заполненным токеном.
- Демо-данные показываются только до первого успешного обновления. После него в `top-donations-data.js` лежат реальные донаты.
- Порядок показа донатеров — по убыванию суммы. Если настроить `topCount` больше 0, будут показаны только первые места.
