# Локальный план финальных изменений

`final-delta-plan.mjs` сравнивает две **полностью проверенные зашифрованные**
генерации Firebase. Это необходимый подготовительный шаг для переноса изменений,
появившихся после первоначальной копии. Он не подключается к облаку или MySQL,
не обновляет staging, не удаляет данные и не переключает приложение.

Исходный `import-clrsx2-mysql84` сохраняет прежний контракт неизменяемого импорта:
новый planner его не обходит и не превращает конфликт обновлённой строки в успех.
Для применения этого плана ещё нужна отдельная проверенная реализация.

## API

```js
import { createFinalDeltaPlan } from './final-delta-plan.mjs';
const plan = await createFinalDeltaPlan({
  before: { archivePath, archiveKey, archiveSha256, manifest, credentials },
  after: { archivePath, archiveKey, archiveSha256, manifest, credentials },
  expectedSource: { project, database, bucket },
  hmacKey,
  expectedHmacKeyId,
  limits: {}, // Разрешено только уменьшать опубликованные FINAL_DELTA_LIMITS.
});
```

Каждая `archiveKey` — 32-байтный Buffer. `hmacKey` общий для обеих генераций и
их schema-v2 manifest; `expectedHmacKeyId` — заранее закреплённый идентификатор
этого ключа. Источник проверяется по явно заданным project, database, bucket и
HMAC manifest. Два `archiveSha256` должны быть заранее закреплены и различаться.
Файлы должны быть завершёнными, закрытыми от группового/общего чтения и находиться
вне репозитория. API не возвращает ключи и не меняет переданные Buffer.

Для sealed bundle нужен **композитный** SHA существующего archive reader:
индекс, затем ciphertext shards в указанном порядке. Обычный SHA одного
`full.clrsenc` не заменяет этот pin. Короткий предварительный проход аутентифицирует
индекс и ограничивает сумму его размера и всех shards; затем shared importer
один раз полностью проверяет каждый shard, порядок кадров, end, итоговые числа,
размеры и SHA объектов. Для одиночного архива предварительно читается только
первый аутентифицированный кадр, после него выполняется полный проход.

`credentials` необязателен, но при использовании обязателен **в обеих**
генерациях:

```js
credentials: { archivePath, archiveKey, archiveSha256 }
```

Это отдельный Auth credentials-only архив. Его источник, hash configuration,
каждая запись и итоговые числа проверяются существующими schema validators.
UID, disabled, emailVerified, providers и время отзыва токенов должны точно
совпасть с Auth соответствующей основной генерации. Неполная пара отклоняется.
Без пары остаётся blocker `credentials_unknown`: основной экспорт намеренно не
содержит password hashes, поэтому по нему нельзя установить изменение пароля.
`passwordVerifierChanged` означает изменение материала verifier, а не доказательство
изменения открытого пароля. Изменение конфигурации хеширования и отсутствие
пригодного password material выделяются отдельно.

## Что входит в план

- Auth: появление, изменение, отсутствие; отключение/включение аккаунта,
  провайдеры, email verification, claims и metadata отзыва токенов.
- Firestore: точное изменение typed payload, content, create/update time,
  lifecycle профиля и привязок медиа. Int64 сравнивается по исходной typed строке,
  без округления SDK Number. Совместимый schema-v2 content HMAC проверяется отдельно.
- Storage: появление, отсутствие, изменение SHA содержимого или точной metadata,
  включая generation, metageneration и download token.
- Credentials: изменение verifier/material availability и hash configuration;
  никакой verifier или конфигурационный секрет не попадает в результат.

Идентификаторы — детерминированные HMAC; текст, email, UID, пути документов,
названия collection, Storage URL/ключи, download tokens, raw content hashes и
ключи шифрования не выходят в JSON. Есть только агрегированные числа, HMAC
идентичности, фиксированные названия причин, SHA зашифрованных входов и плана.
Список неизменившихся записей не раздувает результат.

Отсутствие — всегда `missingCandidate` с `deletionAuthorized: false`, а не
инструкция удаления. Неполные scoped archives отклоняются. Независимый дочерний
документ продолжает учитываться по своему полному пути, даже если его родитель
исчез; от отсутствующего родителя не выводится исчезновение всей ветки.
Даже два полных экспорта могут представлять разные моменты жизни активного
источника, поэтому отсутствие нельзя автоматически считать подтверждённым удалением.

## Ограничения и доказательство переключения

Пределы на каждую основную генерацию: 10 000 Auth, 100 000 документов, 10 000
объектов, 7,2 GB Storage, 64 MB на объект, 9 GB суммарного ciphertext, 256 MB
serialized metadata, 64 MB retained index, 150 000 references. Manifest ограничен
32 MB, отдельные credentials — 20 MB, план — 64 MB и суммарно 150 000 изменений.
Ключи, metadata и decoded typed values живут только в памяти; Storage буферизуется
существующим importer по одному ограниченному объекту. Верхние пределы не являются
обещанием низкого потребления памяти: maps, sets и JSON имеют дополнительный overhead.
CLRSX2 не использует сжатие; shared reader ограничивает кадр 4 MiB и bytes chunk
256 KiB. Тихой распаковки, рекурсивных unbounded JSON trees и чтения всего media
архива в один Buffer нет. Ошибки внешнего API/CLI обобщены без приватных путей.

`cutoverReady`, `automaticApply` и `deletionAuthorized` **всегда false**.
Даже `snapshotConsistent: true` / `finalSyncRequired: false` из входного
архива — только диагностические метки, не доверенное доказательство.
Текущий segmented export сохраняет `snapshotConsistent: false` и
`finalSyncRequired: true`; этот planner не меняет их и не объявляет источник
согласованным. Для переключения всё ещё необходимо отдельно подтвердить:

1. Реально установленный барьер записей на Firebase, включая Auth, Firestore,
   Storage, фоновые процессы и старые версии приложения.
2. Полноту и согласованность финального покрытия внутри этого барьера;
   отсутствие записи проверяется независимо, включая missing parents/descendants.
3. Проверенное применение финальных изменений и разрешение конфликтов staging,
   включая credentials, отключённые аккаунты, сессии и медиа-привязки.
4. Сверку состояния назначения и вход существующих пользователей перед
   включением Timeweb в приложении.

Эти доказательства не принимаются через необязательный флаг config или manifest.
Planner оставляет явные blockers; другой этап должен проверить реальные события.

## CLI

Подготовить приватный config вне Git/APK с mode 0600:

```json
{
  "format": 1,
  "expectedSource": { "project": "SOURCE", "database": "(default)", "bucket": "SOURCE_BUCKET" },
  "expectedHmacKeyId": "PINNED_HMAC_KEY_ID",
  "hmacKeyFile": "/private/hmac.key",
  "before": {
    "archivePath": "/private/before/full.clrsenc",
    "archiveSha256": "PINNED_COMPOSITE_CIPHERTEXT_SHA256",
    "keyFile": "/private/archive.key",
    "manifestFile": "/private/before/manifest.json"
  },
  "after": {
    "archivePath": "/private/after/full.clrsenc",
    "archiveSha256": "PINNED_COMPOSITE_CIPHERTEXT_SHA256",
    "keyFile": "/private/archive.key",
    "manifestFile": "/private/after/manifest.json"
  }
}
```

При необходимости добавить в **обе** generation секции `credentials` с
`archivePath`, `archiveSha256`, `keyFile`. Пароли и секреты в config не вставлять:
ключи читаются из отдельных приватных файлов. Config ограничен 64 KB.

```sh
node server/timeweb/final-delta-plan.mjs --config /private/final-delta.json --out /private/final-delta-plan.json
node --test server/timeweb/test/final-delta-plan.test.mjs
```

Выход создаётся mode 0600 вне репозитория через `wx` temporary file и hard link
только после полной проверки обеих генераций. Существующий файл, в том числе
исходный архив, никогда не перезаписывается. Stdout содержит только числа и SHA
плана. Проверки используют маленькие синтетические зашифрованные fixtures:
реальные пользовательские архивы и cloud API при разработке не читались.
