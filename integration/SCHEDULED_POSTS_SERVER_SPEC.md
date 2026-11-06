# Спецификация для бэкенд-разработчика: Публикация постов по расписанию (Отложенный постинг)

Этот документ описывает изменения на сервере (`python_server`) и в клиентском приложении для реализации отложенных публикаций (как в ВК).

---

## 1. Изменения в базе данных (Схема БД)

В таблицу/коллекцию постов (например, `posts`) необходимо добавить два новых поля:
1. `status` (ENUM или VARCHAR): Статус публикации. Возможные значения:
   - `'published'` (опубликован в ленте)
   - `'scheduled'` (отложен, ждет времени публикации)
   - `'draft'` (черновик)
2. `scheduled_at` (TIMESTAMP / DATETIME, NULLABLE): Время, в которое пост должен быть автоматически опубликован. Для обычных постов равно `NULL`.

---

## 2. Спецификация API (Endpoints)

### А. Создание / Обновление поста с расписанием
При создании или редактировании поста клиент передает опциональное поле `scheduled_at` (в формате ISO 8601 UTC).

- **Request (POST / PUT):**
  ```json
  {
    "kind": "publish",
    "text": "Текст отложенного поста...",
    "mediaIds": ["media_id_1"],
    "scheduled_at": "2026-11-01T15:00:00Z"
  }
  ```
- **Логика сервера:**
  - Если `scheduled_at` передано и больше текущего времени (`NOW()`), то устанавливать `status = 'scheduled'` и сохранять `scheduled_at`.
  - Если `scheduled_at` отсутствует или в прошлом, устанавливать `status = 'published'` и `scheduled_at = NULL`.

### Б. Получение списка отложенных постов автора
Эндпоинт для получения постов текущего пользователя, которые еще не опубликованы.
- **Request:** `GET /api/v1/posts/scheduled`
- **Response:**
  ```json
  {
    "items": [
      {
        "id": "tw-post-...",
        "text": "...",
        "scheduled_at": "2026-11-01T15:00:00Z"
      }
    ]
  }
  ```

---

## 3. Серверный воркер (Background Task / Cron Job в Python)

Для автоматической публикации отложенных записей на бэкенде (`python_server`) требуется фоновый процесс (например, задача по расписанию через `apscheduler`, `celery` или простой `while True` цикл с задержкой 60 секунд).

### Логика воркера:
```python
import time
from datetime import datetime

def publish_scheduled_posts_worker():
    while True:
        now = datetime.utcnow()
        # 1. Найти все посты со статусом scheduled, у которых подошло время
        posts_to_publish = db.query(
            "SELECT * FROM posts WHERE status = 'scheduled' AND scheduled_at <= %s",
            (now,)
        )
        
        for post in posts_to_publish:
            # 2. Обновить статус на published
            db.execute(
                "UPDATE posts SET status = 'published', updated_at = %s WHERE id = %s",
                (now, post['id'])
            )
            # 3. Опционально: отправить push-уведомление автору или подписчикам
            print(f"Published scheduled post {post['id']}")
            
        time.sleep(60) # проверка каждую минуту
```

---

## 4. Клиентская реализация (Flutter UI)

В `PostEditorPage` добавляется кнопка выбора времени (иконка календаря/часов):
1. Вызов системного пикера даты и времени (`showDatePicker` + `showTimePicker`).
2. Сохранение выбранного времени в переменную `DateTime? _scheduledAt`.
3. При отправке формы параметр `scheduled_at` передается в полезной нагрузке запроса.
