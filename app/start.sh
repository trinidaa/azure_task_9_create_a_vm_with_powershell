#!/bin/bash
# Переходим в рабочую директорию
cd /app || exit 1

# Абсолютные пути к бинарникам
PYTHON=/usr/bin/python3
PIP=/usr/bin/pip

# Установка зависимостей
$PIP install -r requirements.txt || {
    echo "Failed to install requirements"
    exit 1
}

# Применение миграций
$PYTHON manage.py migrate || {
    echo "Failed to apply migrations"
    exit 1
}

# Запуск сервера (используем nohup для демонизации)
exec $PYTHON manage.py runserver 0.0.0.0:8080