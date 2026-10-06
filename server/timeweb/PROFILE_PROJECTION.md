# Узкая проекция Auth и профилей в существующую MySQL 8.4

Статус на 30.09.2026: **код, адресные synthetic tests и настоящий metadata dry-run готовы; записей в MySQL этим шагом не выполняли**. Этот шаг заполняет `accounts`, `auth_identities`, `profiles`, которые читает Python `GET /v1/me/profile`. Он не превращает архив `legacy_*` в полностью работающий backend приложения.

Новая платная инфраструктура, DDL, изменения Flutter, подарков и оплаты этому шагу не нужны. Архивы, ключи, пароли и rollback receipt остаются вне Git/APK.

## Что установлено по исходникам и настоящему архиву

Посмотрены только имена/типы полей и агрегаты, без вывода UID, почт, имён, текстов профилей и файлов пользователей. Корневые `users/{uid}` сопоставляются с Auth по **ID документа**, как в действующем Flutter. Сопоставление по похожим почтам/именам запрещено.

Исходники: `lib/core/utils/account_destination.dart`, `compatibility.dart`, сервисы регистрации/удаления профиля, `profile_composition.dart`; структура — `db/001_initial_mysql84.sql`. Python API выбирает `accounts.disabled/lifecycle` и `profiles.full_name/country/city/primary_group` только по UID подтверждённого токена. Оно отклоняет отсутствующий, disabled/blocked/deleted аккаунт и отсутствующий `full_name`.

Завершённый metadata-архив не содержит Storage и password hashes. Он имеет `scope=metadata`, `completeSource=false`; его завершённые Auth/Firestore-секции можно использовать для этой узкой проекции. Для полного переезда нужен полный экспорт и финальная синхронизация. Незавершённые `.partial-*` файлы запрещены.

| Агрегат настоящего metadata dry-run | Количество |
|---|---:|
| Auth / создаваемые accounts | 8 202 |
| Фактические providerData / auth_identities | 8 202 |
| Корневые документы users | 6 097 |
| Профили, имеющие тот же UID в Auth | 6 025 |
| Root users без Auth; остаются в legacy_documents | 72 |
| Auth без корневого профиля; профиль не выдумывается | 2 177 |
| disabled аккаунты | 0 |
| blocked аккаунты | 4 |
| deleted аккаунты в этой проекции | 0 |
| Сохранённые admin:true в этом раннем снимке | 0 |
| Импортируемые профили без country; сохраняется NULL | 6 023 |
| Профили с исходно пустым fullName; сохраняется пустая строка | 4 |

У шести корневых документов `uid=null`, строковых конфликтов UID с ID документа нет. У всех 6 097 корневых профилей `status` — typed string: 6 093 `active`, 4 `blocked`. `country` присутствует только у двух новых профилей. Комбинированная группа — один строковый код из существующих 16 русских значений; 98 корневых профилей имеют пустую группу. Названия страны/города не переводятся и не заменяются значениями по умолчанию.

Привязка этого dry-run:

- encrypted archive SHA-256: `f2a8ca333c4d3af36ffb0ceb2c031ad668e7ce6f0be90ddd824934f3b584b8ee`;
- projection SHA-256: `2550ac7bb5a4986f495b896416c0e859f1fccecfd9435ee12881cd4b6d4aa3b3`;
- `databaseWrites=0`, `passwordMaterialRead=false`.

**Эти количества и claims относятся только к данному снимку.** В проекте продолжают появляться аккаунты и менялись admin claims. Перед включением сервера нужен свежий экспорт и повторный dry-run именно его; старые количества нельзя применять к другому архиву.

## Отображение данных

| Источник | Назначение | Правило |
|---|---|---|
| Auth.uid | accounts.uid | Строка без изменения, максимум 191 символ |
| Auth.email | accounts.email_normalized | trim + lowercase; оригинал остаётся в legacy_auth_users |
| Auth.emailVerified / disabled | accounts.email_verified / disabled | Только фактические boolean |
| users/{UID}.status | accounts.lifecycle | active/blocked/deleted; неизвестный статус блокирует план; отсутствие статуса соответствует текущему Flutter и означает active |
| Auth.metadata | firebase_created_at / firebase_last_login_at | UTC; отсутствие сохраняется NULL |
| Auth.customClaims | accounts.legacy_claims | Полный объект без удаления остальных claims; отсутствие означает `{}` на дату снимка |
| Auth.providerData | auth_identities | Только фактические providerId/uid/email; нет выдуманной identity для отсутствующего провайдера |
| users/{UID}.fullName | profiles.full_name | Исходная строка, включая пустую; отсутствие/typed null остаётся NULL |
| country / city | profiles.country / city | Исходные строки; отсутствующие значения NULL |
| группа | profiles.primary_group | Полная комбинированная группа без разбиения и перевода; secondaryGroup переносится только из одноимённого исходного поля |
| age / rost / about / hobbi / deti / pol / relationStatus / countryCode / region / languageCode / secondaryGroup | Соответствующие canonical columns | Strict details projector, точные правила ниже; missing/typed null сохраняются NULL в nullable columns |
| profileDetailsSaved / isRegistrationEnd | Соответствующие flags | Фактический boolean; при отсутствии false, как в текущем Flutter; typed null не помещается в NOT NULL и блокирует plan; точное отсутствие видно в legacy_raw |
| createTime / updateTime + все typed fields | profiles.legacy_raw | Полный исходный объект; целые числа Firestore остаются typed strings |
| updateTime | profiles.updated_at | UTC до шести дробных цифр, поддерживаемых MySQL; nanoseconds полностью сохраняются в legacy_raw |

`token_version=0` — новая версия токенов Timeweb на старте, не перенос Firebase refresh/session токенов. Прежние `tokensValidAfterTime` остаются в `legacy_auth_users`, их применение относится к отдельному auth/session шагу.

Strict initial-import mapping находится в `project-profile-details.mjs`.
Export `projectProfileDetails(fields)` возвращает ровно `PROFILE_DETAILS_COLUMNS`:
`age,height_cm,about_text,interests_text,has_children,gender,relationship_status,
country_code,region,language_code,secondary_group,profile_details_saved,registration_complete`.
Один helper используется initial profile plan и conversation dependencies; эти
columns включены в parameterized initial INSERT и полный expected-row proof.
Нормализованные `invisible_until/last_online_at` остаются NULL, test_result — `{}`.
Visibility/deadlines, деньги, роли, source lifecycle/raw и timestamps не меняются.

Source value — объект ровно с одним Firestore type key. Отсутствие/explicit
`nullValue` сохраняется NULL в nullable колонках. Strings сохраняются без trim,
Unicode normalization/aliases; считаются Unicode code points и strict UTF-8.
`about/hobbi` допускают исходные short/empty строки до4096; pol/relationStatus,
languageCode/secondaryGroup — до191; countryCode — прежние20. ISO/catalog/enum
проверки на historical текст этим initial mapping не накладываются. languageCode
не выводится из language/languageGroup/countrySegment; secondaryGroup не выводится
из group/комбинированной группы; region не выводится из city.

Representable age: legacy integerValue/stringValue с1..3 ASCII digits либо finite
integral doubleValue, затем exact schema range0..130. Source age131..150,
дробный double или неверная typed форма прекращают plan. rost в legacy decoder
и Firestore write-source — stringValue: только непустая ASCII цифровая строка
точного численного значения0..300 преобразуется в height_cm INT; leading zeros
не меняют число и остаются в raw. Пустая строка, units, пробелы, дробь, другой
type tag или число вне0..300 не заменяются наNULL/округлённое значение. Region
192..1000 допустим старому reader, но не помещается в существующий VARCHAR191:
plan останавливается, schema не расширяется.

`ProfileDetailsProjectionError` содержит только `field` и `reason`, без UID,
значений профиля или raw payload. Причины несовместимости конкретной строки:

| Reason | Отказ |
|---|---|
| schema_integer_range | age вне0..130 или rost вне0..300 |
| fractional_number | дробный age |
| expected_integer_string | rost не является непустой ASCII цифровой строкой |
| schema_string_bound | строка превышает canonical bound, в частности region>191 |
| source_string_bound | строка превышает retained reader bound, в частности countryCode>20 |
| schema_not_nullable | explicit null в saved/completed flags |
| invalid_typed_field / expected_string / expected_boolean / expected_integer_digits / expected_finite_number / invalid_utf8 | повреждённый или неподдержанный source type |

Исходные record hashes/archive SHA и исходный updateTime не меняются. Canonical
projection/dependency digest меняется вместе с plan; receipt старого plan не
является подтверждением нового. Stage требует empty normalized tables и
использует INSERT, без upsert/UPDATE. Readback/rollback отказывают при later
native edit в любом projected column. Этот source fix относится к будущему
первоначальному импорту: **существующие6031 rows не обновляет**. Отдельный additive
backfill потребует доказанного первоначального baseline/source и запрета
перезаписи native edits. Полный cutover/public directory этим шагом не включается.

`legacy_claims` сохраняет проверенные серверные Auth claims; проекция не выдаёт `role_grants` по клиентскому `isAdmin`. Для админки нужен свежий снимок claims, затем отдельное проверенное серверное назначение ролей. В раннем metadata-снимке нет новых admin claims.

## Файлы и защиты

- `project-profiles-core.mjs` — полное чтение и аутентификация CLRSX2, проверка end/EOF/counts; план после этого неизменяем. Для `scope=all` проверяются также все Storage checksum/bytes существующим scanner.
- `project-profiles-cli.mjs` — по умолчанию dry-run, без создания MySQL-клиента. Выводит только counts/SHA/scope. Ключ и архив должны быть private regular files вне репозитория, ключ 32 bytes.
- `project-profiles-mysql84.mjs` — только существующая `clrs_staging`, MySQL 8.4, utf8mb4, strict session, schema version 1. Источник сверяется с `legacy_source`, все Auth и корневые users — с оригинальными legacy ID/path и полным payload/hash.
- Stage требует пустые три нормализованные таблицы, совпадение SHA и явное подтверждение **обоих** количеств отсутствующих связей. Никаких upsert/UPDATE и удаления конфликтующей строки.
- Все исходные значения идут через mysql2 placeholders. Batch ограничен 100 записями **и** UTF-8 размером параметров/JSON. До первого INSERT читается `max_allowed_packet`, используется максимум половины этого лимита с запасом на протокол. Слишком большая одиночная строка прекращает transaction до INSERT; серверный лимит не увеличивается. Имена таблиц/колонок заданы в коде. Один SERIALIZABLE transaction; INSERT и последующая полная сверка связей/значений атомарны.
- TLS берётся из существующего `mysql84Config`: DNS host, официальный CA, `rejectUnauthorized=true`, `verifyIdentity=true`, явное `MYSQL_DATABASE=clrs_staging`, `multipleStatements=false`. Пароли только из серверного/private окружения, без CLI-флагов.
- Ошибки CLI не печатают mysql2 error body/SQL/параметры, чтобы исключить утечку пользовательских данных.

## Dry-run

Запускать из корня репозитория на Node 22. Пути ниже — примеры, ключ/пароли туда не вставлять:

```sh
node server/timeweb/project-profiles-cli.mjs \
  --archive /secure/firebase-final.clrsenc \
  --key-file /secure/export.aes.key \
  --project chatapp-4e347 \
  --database '(default)' \
  --bucket chatapp-4e347.appspot.com \
  --mode dry-run
```

Это единственный выполненный режим на настоящих данных. Dry-run не читает credential archive и не открывает соединение с MySQL.

## Будущий stage и проверка

Перед записью оператор должен закончить и проверить raw-импорт того же архива, выбрать свежий snapshot/final-sync порядок, просмотреть dry-run и резервную копию. API пока оставить read-only, без пользовательских записей в нормализованные таблицы. Данный агент stage не запускал.

При уже безопасно загруженных private env `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE=clrs_staging`, `MYSQL_CA_FILE`:

```sh
node server/timeweb/project-profiles-cli.mjs \
  --archive /secure/firebase-final.clrsenc \
  --key-file /secure/export.aes.key \
  --project chatapp-4e347 --database '(default)' \
  --bucket chatapp-4e347.appspot.com --mode stage \
  --confirm-target-db clrs_staging \
  --confirm-archive-sha256 REVIEWED_ARCHIVE_SHA256 \
  --ack-orphan-profiles REVIEWED_ORPHAN_COUNT \
  --ack-accounts-without-profile REVIEWED_MISSING_PROFILE_COUNT \
  --receipt-file /secure/profile-projection-rollback.clrsenc
```

Receipt записывается AES-GCM и синхронизируется, включая каталог, **перед COMMIT**. В нём SHA проекции/архива, counts и timestamp новых accounts, без пользовательских значений. Каталог должен быть private, существующий receipt запрещает новый stage. При ошибке создания receipt вся транзакция отменяется.

Если COMMIT потерял ответ/соединение, receipt означает **prepared/возможно committed**, а не подтверждённый успех. Не удалять receipt и не повторять stage. Проверить тем же архивом:

```sh
node server/timeweb/project-profiles-cli.mjs \
  --archive /secure/firebase-final.clrsenc --key-file /secure/export.aes.key \
  --project chatapp-4e347 --database '(default)' \
  --bucket chatapp-4e347.appspot.com --mode verify \
  --confirm-target-db clrs_staging \
  --confirm-archive-sha256 REVIEWED_ARCHIVE_SHA256 \
  --receipt-file /secure/profile-projection-rollback.clrsenc
```

Verify — read-only transaction; сверяет точные counts, UID/FK, исходные payloads и нормализованные значения. С receipt проверяет и timestamps вставки. Не подменяет живой authenticated GET через развёрнутый API и проверку отказа на чужой UID/disabled/blocked account.

## Rollback

Автоматический `ROLLBACK` внутри незавершённой транзакции не требует удаления сохранённых данных. Для отмены уже committed проекции подготовлен отдельный `--mode rollback` с теми же параметрами, count acknowledgements, receipt и **дополнительным** `--confirm-rollback-archive-sha256 REVIEWED_ARCHIVE_SHA256`.

Он повторно проверяет весь источник, неизменность всех нормализованных значений, точные общие counts и timestamps вставки. Только после этого удаляет свои auth_identities → profiles → accounts по параметризованным UID в одном transaction. `legacy_*`, encrypted export, credentials, фотографии и любые другие домены не удаляет. Новая/изменённая строка, изменённое ранее не проецированное поле, другой receipt или внешний FK прекращают rollback; уже удалённые в transaction строки восстанавливаются его отменой.

Временный `clrs_migrate` имеет только CREATE/REFERENCES/SELECT/INSERT/UPDATE и **не имеет DELETE**. Перед любыми DELETE rollback CLI проверяет прямые `SHOW GRANTS` и прекращается, если DELETE не подтверждён на каждой из трёх staging-таблиц; глобальные права запрещены. Committed rollback должен выполняться оператором с отдельным минимальным DELETE на этих трёх staging-таблицах; этот доступ не добавляли и автоматически не расширяют. После подключения credentials/других FK нужен согласованный backup/restore для всего этапа, а не удаление accounts в обход ограничений.

Пока приложение работает через Firebase, рабочий operational rollback — прежняя Firebase-сборка/конфигурация; исходники, источники Firebase, `legacy_*` и encrypted backup сохраняются. Возможность этого fallback не означает, что post-commit DELETE доступен миграционной роли, или что новое полное переключение уже проверено.

## Проверки и оставшаяся граница

`node --test server/timeweb/test/project-profiles.test.mjs`: 15/15 адресных тестов. Покрыты encrypted truncation/tag corruption/trailing/count mismatch, source confirmation, limits, отказ password material/credential records, UID mismatch, unknown lifecycle, duplicate emails/providers, tenant guard, параметры SQL, точный legacy payload, явные target/absence guards, публикация receipt, потерянный ответ COMMIT, immutable rollback и отказ при поздних изменениях/FK. Отдельно проверены byte-bound batches, слишком большой legacy_raw до первого INSERT и отказ committed rollback на текущих пяти правах. В тестах только искусственные данные и transaction-aware MySQL double; настоящих SQL-записей нет.

Реальный metadata dry-run завершился приведёнными counts/SHA. Не выполнены: stage в настоящую MySQL, live `/v1/me/profile` импортированного пользователя, passwords/session login, доменные API и media mapping, полный final-sync/переключение. Успешный dry-run не является завершённым переездом.
