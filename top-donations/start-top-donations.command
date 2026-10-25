#!/bin/bash
# Двойной клик в Finder запускает обновление топа донатов на macOS.

cd "$(dirname "$0")" || exit 1

if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 не найден."
    echo
    echo "Установите его одним из способов:"
    echo "  xcode-select --install"
    echo "или"
    echo "  brew install python"
    echo
    read -r -n 1 -s -p "Нажмите любую клавишу для выхода..."
    echo
    exit 1
fi

python3 top-donations-update.py
status=$?

echo
if [ "$status" -ne 0 ]; then
    echo "Скрипт завершился с ошибкой. Проверьте top-donations-config.json."
fi
read -r -n 1 -s -p "Нажмите любую клавишу для выхода..."
echo
exit "$status"
