#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
#  ТОП ДОНАТОВ ИЗ DONATIONALERTS — macOS / Linux / Windows
# ============================================================
# Аналог top-donations-update.ps1, но на Python 3.
# Нужен, чтобы всё работало на macOS без PowerShell.
#
# Запуск один раз:
#   python3 top-donations-update.py --once
#
# Постоянное обновление (окно Терминала должно быть открыто):
#   python3 top-donations-update.py
#
# Проверка подсчёта без интернета:
#   python3 top-donations-update.py --self-test
# ============================================================

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "top-donations-config.json"
DATA_PATH = ROOT / "top-donations-data.js"
DEFAULT_API_BASE = "https://www.donationalerts.com"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) TopDonationsOverlay/1.0"
EVENT_RE = re.compile(r"addEvent\('((?:\\.|[^'])*)'\)")
SETTINGS_RE = re.compile(r"handleGeneralWidgetSettings\('((?:\\.|[^'])*)'\)")
ANONYMOUS_NAMES = {"anonymous", "аноним", "анонимный", "гость"}
WIDGET_LIMIT = 100

DEFAULTS = {
    "secretToken": "",
    "accessToken": "",
    "topCount": 0,
    "periodDays": 0,
    "maxPages": 0,
    "refreshSeconds": 300,
    "displayCurrency": "RUB",
    "skipAnonymous": False,
}


def log(message: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def default_config() -> dict:
    return dict(DEFAULTS)


def as_bool(value) -> bool:
    if isinstance(value, str):
        return value.strip().lower() not in {"", "0", "false", "no", "нет"}
    return bool(value)


def read_config() -> dict:
    if not CONFIG_PATH.exists():
        payload = {
            "_comment": (
                "secretToken: токен из DonationAlerts (Настройки → Основные → Secret token "
                "или параметр token= в ссылке любого виджета)."
            ),
            **DEFAULTS,
        }
        CONFIG_PATH.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        raise RuntimeError("Создан top-donations-config.json. Впишите secretToken и запустите снова.")

    try:
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Ошибка в top-donations-config.json: {exc}") from exc

    if not isinstance(raw, dict):
        raise RuntimeError("top-donations-config.json должен содержать объект JSON.")

    config = default_config()
    for key in DEFAULTS:
        if key in raw and raw[key] is not None:
            config[key] = raw[key]

    config["secretToken"] = str(config["secretToken"]).strip()
    config["accessToken"] = str(config["accessToken"]).strip()
    config["displayCurrency"] = str(config["displayCurrency"]).strip() or "RUB"
    config["skipAnonymous"] = as_bool(config["skipAnonymous"])

    try:
        config["topCount"] = max(0, min(20, int(config["topCount"])))  # 0 = все донатеры
        config["periodDays"] = max(0, int(config["periodDays"]))
        config["maxPages"] = max(0, int(config["maxPages"]))
        config["refreshSeconds"] = max(30, int(config["refreshSeconds"]))
    except (TypeError, ValueError) as exc:
        raise RuntimeError(f"Ошибка в числовых настройках конфига: {exc}") from exc

    return config


def http_get_text(url: str, headers: dict | None = None) -> str:
    request_headers = {
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Connection": "close",
    }
    if headers:
        request_headers.update(headers)

    request = Request(url, headers=request_headers)
    try:
        with urlopen(request, timeout=60) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            return response.read().decode(charset, errors="replace")
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:300]
        raise RuntimeError(f"HTTP {exc.code} при запросе к DonationAlerts: {body}") from exc
    except URLError as exc:
        raise RuntimeError(f"Сетевая ошибка при запросе к DonationAlerts: {exc.reason}") from exc


def http_get_json(url: str, headers: dict | None = None):
    request_headers = {"Accept": "application/json"}
    if headers:
        request_headers.update(headers)

    text = http_get_text(url, request_headers)
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Сервер вернул не JSON: {text[:200]}") from exc


def js_unescape(text: str) -> str:
    """Разэкранирует JavaScript-строку: \\" \\\\ \\/ \\uXXXX и т.п."""
    result: list[str] = []
    i = 0
    while i < len(text):
        char = text[i]
        if char != "\\":
            result.append(char)
            i += 1
            continue

        i += 1
        if i >= len(text):
            break

        nxt = text[i]
        i += 1
        if nxt == "u" and i + 4 <= len(text):
            try:
                result.append(chr(int(text[i:i + 4], 16)))
                i += 4
            except ValueError:
                result.append("u")
        elif nxt in "\"'\\/":
            result.append(nxt)
        elif nxt == "b":
            result.append("\b")
        elif nxt == "f":
            result.append("\f")
        elif nxt == "n":
            result.append("\n")
        elif nxt == "r":
            result.append("\r")
        elif nxt == "t":
            result.append("\t")
        else:
            result.append(nxt)

    return "".join(result)


def parse_donation_date(donation: dict) -> datetime | None:
    for key in ("created_at_ts", "date_created_ts"):
        value = donation.get(key)
        if value is None:
            continue
        try:
            timestamp = float(value)
        except (TypeError, ValueError):
            continue
        if timestamp > 100_000_000_000:
            timestamp /= 1000
        if timestamp > 0:
            return datetime.fromtimestamp(timestamp)

    for key in ("created_at", "date_created"):
        value = donation.get(key)
        if not value:
            continue
        try:
            return datetime.strptime(str(value), "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue

    return None


def get_widget_data(
    secret: str,
    api_base: str,
    period_days: int,
    limit: int = WIDGET_LIMIT,
) -> tuple[list[dict], str, int]:
    """Читает последние донаты со страницы виджета lastdonations.

    Официальный OAuth API не нужен: страница доступна по secretToken.
    Возвращает (события, валюта, лимит виджета).
    """
    if not secret:
        raise RuntimeError("В top-donations-config.json не заполнен secretToken.")

    log("Загружаю последние донаты из виджета DonationAlerts...")
    url = (
        f"{api_base}/widget/lastdonations?alert_type=1,12"
        f"&limit={limit}&token={quote(secret, safe='')}"
    )
    html = http_get_text(url)

    events: list[dict] = []
    for match in EVENT_RE.finditer(html):
        try:
            event = json.loads(js_unescape(match.group(1)))
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)

    currency = ""
    settings_match = SETTINGS_RE.search(html)
    if settings_match:
        try:
            settings = json.loads(js_unescape(settings_match.group(1)))
            currency = str(settings.get("main_currency") or "")
        except json.JSONDecodeError:
            pass

    if not events and not settings_match:
        raise RuntimeError("Не удалось прочитать данные виджета. Проверьте secretToken.")

    if period_days > 0 and events:
        cutoff = datetime.now() - timedelta(days=period_days)
        events = [
            event
            for event in events
            if (created := parse_donation_date(event)) is None or created >= cutoff
        ]

    return events, currency, limit


def get_top_donors(
    donations: list[dict],
    top_count: int,
    skip_anonymous: bool,
    currency: str,
) -> list[dict]:
    users: dict[str, dict] = {}

    for donation in donations:
        name = str(donation.get("username") or "").strip()
        is_anonymous = not name or name.casefold() in ANONYMOUS_NAMES

        if is_anonymous and skip_anonymous:
            continue
        if is_anonymous:
            name = "Аноним"

        alert_type = str(donation.get("alert_type") or "").strip()
        if alert_type and alert_type not in {"1", "12"}:
            continue

        # amount_main и amount_in_user_currency — суммы в основной валюте стримера.
        amount = 0.0
        for field in ("amount_main", "amount_in_user_currency", "amount"):
            try:
                value = float(donation.get(field) or 0)
            except (TypeError, ValueError):
                value = 0.0
            if value > 0:
                amount = value
                break

        if amount <= 0:
            continue

        key = name.casefold()
        if key not in users:
            users[key] = {
                "username": name,
                "amount": 0.0,
                "donations": 0,
                "currency": currency,
            }
        users[key]["amount"] += amount
        users[key]["donations"] += 1

    result = sorted(
        users.values(),
        key=lambda item: (-item["amount"], item["username"].casefold()),
    )
    if top_count <= 0:
        return result  # 0 = показывать всех донатеров
    return result[:top_count]


def write_top_file(rows: list[dict], currency: str, period_label: str) -> None:
    ordered = [
        {
            "username": str(row["username"]),
            "amount": round(float(row["amount"]), 2),
            "currency": currency,
            "donations": int(row["donations"]),
        }
        for row in rows
    ]

    json_text = json.dumps(ordered, ensure_ascii=False, indent=4)
    timestamp = int(time.time())
    content = (
        "// Этот файл создаётся автоматически (top-donations-update.py)\n"
        f"// Обновлено: {datetime.now():%Y-%m-%d %H:%M:%S}\n"
        f"window.TOP_DONATIONS = {json_text};\n"
        f"window.TOP_DONATIONS_CURRENCY = '{currency}';\n"
        f"window.TOP_DONATIONS_PERIOD = '{period_label}';\n"
        f"window.TOP_DONATIONS_UPDATED = {timestamp};\n"
        "window.TOP_DONATIONS_IS_DEMO = false;\n"
    )

    # Пишем через временный файл, чтобы OBS не прочитал недописанный файл.
    temp_path = DATA_PATH.with_name(DATA_PATH.name + ".tmp")
    with open(temp_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)
    os.replace(temp_path, DATA_PATH)
    log(f"Готово. В топе мест: {len(ordered)}, валюта: {currency}.")


def update_top_donations(config: dict, api_base: str) -> None:
    donations, currency, widget_limit = get_widget_data(
        config["secretToken"],
        api_base,
        config["periodDays"],
    )

    currency = currency or config["displayCurrency"]
    currency = re.sub(r"[^A-Za-z]", "", currency).upper() or "RUB"
    log(f"Загружено донатов: {len(donations)}.")

    rows = get_top_donors(
        donations,
        config["topCount"],
        config["skipAnonymous"],
        currency,
    )

    if config["periodDays"] > 0:
        period_label = f"за {config['periodDays']} дн."
    elif len(donations) >= widget_limit:
        period_label = "по последним донатам"
    else:
        period_label = "за всё время"

    write_top_file(rows, currency, period_label)


def self_test() -> int:
    sample = [
        {"username": "Ivan", "amount": 100, "amount_in_user_currency": 100, "alert_type": "1"},
        {"username": "ivan", "amount": 50, "amount_in_user_currency": 50, "alert_type": "1"},
        {"username": "Masha", "amount": 100, "amount_main": 300, "alert_type": "1"},
        {"username": "Anonymous", "amount": 999, "amount_main": 999, "alert_type": "1"},
        {"username": "", "amount_main": 40, "alert_type": "1"},
        {"username": "Oleg", "amount": 0, "amount_main": 0, "alert_type": "1"},
    ]
    rows = get_top_donors(sample, 3, True, "RUB")

    print(f"{'username':<12} {'amount':>8} {'donations':>10}")
    print("-" * 32)
    for row in rows:
        print(f"{row['username']:<12} {row['amount']:>8.0f} {row['donations']:>10}")

    assert len(rows) == 2, "должно остаться два донатера"
    assert rows[0]["username"] == "Masha" and rows[0]["amount"] == 300, "amount_main не учтён"
    assert rows[1]["username"] == "Ivan" and rows[1]["amount"] == 150, "группировка по нику сломана"

    rows_all = get_top_donors(sample, 10, False, "RUB")
    anonymous = [row for row in rows_all if row["username"] == "Аноним"]
    assert anonymous and anonymous[0]["amount"] == 1039, "анонимные донаты не сгруппированы"
    assert js_unescape(r'{\"id\":\"1\"}') == '{"id":"1"}', "js_unescape сломан"
    assert parse_donation_date({"date_created": "2026-10-21 13:00:00"}) is not None
    print("Self-test: OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Топ донатов DonationAlerts для OBS")
    parser.add_argument("--once", action="store_true", help="обновить один раз и выйти")
    parser.add_argument("--self-test", action="store_true", help="проверить подсчёт без сети")
    parser.add_argument(
        "--api-base",
        default=os.environ.get("DA_API_BASE", DEFAULT_API_BASE),
        help="адрес API (для тестов)",
    )
    args = parser.parse_args()
    api_base = args.api_base.rstrip("/")

    if args.self_test:
        return self_test()

    if args.once:
        try:
            update_top_donations(read_config(), api_base)
            return 0
        except Exception as exc:  # noqa: BLE001 — показываем понятную ошибку
            print(f"Ошибка: {exc}", file=sys.stderr)
            return 1

    print("Топ донатов: обновление запущено. Окно не закрывайте.", flush=True)
    while True:
        try:
            update_top_donations(read_config(), api_base)
        except KeyboardInterrupt:
            print("\nОстановлено.")
            return 130
        except Exception as exc:  # noqa: BLE001 — в цикле продолжаем работать
            print(f"Ошибка: {exc}", file=sys.stderr)

        try:
            refresh = max(30, int(read_config().get("refreshSeconds", 300)))
        except Exception:
            refresh = 300

        print(f"Следующее обновление через {refresh} сек. Окно не закрывайте.", flush=True)
        try:
            time.sleep(refresh)
        except KeyboardInterrupt:
            print("\nОстановлено.")
            return 130


if __name__ == "__main__":
    raise SystemExit(main())
