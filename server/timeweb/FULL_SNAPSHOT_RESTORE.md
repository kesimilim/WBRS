# Восстановление текущего encrypted FULL snapshot

Порядок для существующей `clrs_staging` MySQL 8.4 и приватного S3 Timeweb. Документ не запускает restore, DDL, новые ресурсы или пользовательские записи. Чтение сохранённого архива и локальные tests подтверждены; успешное восстановление назначения нужно подтвердить отдельными `verify`.

## Зафиксированный источник

FULL source: `chatapp-4e347`, `(default)`, `chatapp-4e347.appspot.com`.

| Содержимое завершённого архива | Количество |
|---|---:|
| Auth users | 8 208 |
| Firestore documents | 70 486 |
| Storage objects | 6 478 |
| Storage plaintext bytes | 6 932 196 752 |

Composite archive SHA-256, включающий encrypted index и **все** перечисленные shards:
`b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e`.

FINAL manifest SHA-256:
`82352a0bb8a172fc33034204be2a3a752bcac69cc971f0feeb9a177ebcb3a341`.

Private recovery set находится вне Git в `work/private_migration_20260930`:

- `firebase-segmented-20261001/full.clrsenc` и все `metadata.clrsenc` / `storage-*.clrsenc` этого каталога;
- `export.aes.key`, `manifest.hmac.key`, `firebase-segmented-manifest-20261001.json`;
- `segmented-export-verification-20261001.json` со статусом `verified_local_full_export`;
- отдельный encrypted credential bundle со всеми password hash/salt и Firebase SCRYPT project hashConfig, его отдельный AES key и отчёт проверки;
- native credential wrapping key и точный `configRef`, private CA/config, encrypted receipts и aggregate dry-run/verify reports каждого применённого этапа.

Каталоги — 0700, ключи/архивы/receipts — 0600. Не раскрывать значения ключей, пароли или содержимое пользователей. Одного index без shards недостаточно. Hardlinks на том же диске экономят место, но **не являются независимой резервной копией от отказа этого диска**. Перенос recovery set на уже предоставленный независимый носитель требует полной проверки скопированного источника; новый bucket здесь не создаётся.

Снимок был получен из меняющегося Firebase: `snapshotConsistent=false`, `finalSyncRequired=true`. Он позволяет восстановить именно сохранённое состояние, но не доказывает наличие всех более поздних сообщений/аккаунтов. Финальный порядок — [FINAL_SOURCE_SYNC.md](FINAL_SOURCE_SYNC.md).

## До записи в назначение

1. Полностью прочитать FULL через `scanImportArchive`, затем сверить FINAL schema-v2 HMAC manifest через `verifyExportManifest`. Требуются authenticated end/EOF каждого файла, ciphertext и plaintext SHA, source identity и точные counts выше. `.partial` / `.incomplete` / metadata-only источники не принимать.
2. Проверить существующую схему версии1: 42 таблицы /66 FK, MySQL8.4, strict session, `utf8mb4`, DNS-host + официальный CA + TLS `verifyIdentity=true`. У текущей migration роли ровно CREATE, REFERENCES, SELECT, INSERT, UPDATE только на `clrs_staging`; к `default_db` этот порядок отношения не имеет.
3. Проверить control-plane type private, owner-only ACL, отсутствие public policy и запрет анонимного чтения S3. Для raw stage использовать bounded MySQL/S3 clients; S3 `maxAttempts=1`, absolute и idle deadlines описаны в [S3_IMPORT_RUNTIME.md](S3_IMPORT_RUNTIME.md).
4. Оставить API пользовательских записей выключенным. Новый restore выполняется только в уже подготовленные пустые таблицы соответствующего этапа. Если там есть данные, сначала `verify` с прежним FULL и receipts; не удалять/перезаписывать записи ради нового снимка. Подготовка/очистка назначения администратором — отдельная операция, этот документ DDL не выполняет.

## Последовательность восстановления и доказательства

Каждый CLI сначала запускается с `--mode dry-run`; source/private inputs те же. Явные `--confirm-*` и `--ack-*` брать из dry-run этого FULL, а не из старого metadata отчёта. Команды и остальные параметры приведены в связанных инструкциях; секреты передаются через private config, никогда строками CLI.

| Этап | CLI и порядок | Условие принятия |
|---|---|---|
| Raw + media | [import-clrsx2-mysql84.mjs](import-clrsx2-mysql84.mjs): dry-run → stage → новое соединение verify | `legacy_source` bound к исходному project/DB/bucket; 8 208 Auth, 70 486 documents, 6 478 objects /6 932 196 752 bytes. Каждая raw запись и каждый объект S3 сверены полностью: typed JSON, размер, SHA, metadata, карантинный key и owner-only ACL. Только counts или HEAD недостаточно. |
| Account/profile | [PROFILE_PROJECTION.md](PROFILE_PROJECTION.md): dry-run → stage с новым encrypted receipt → receipt-bound verify | 8 208 accounts, 8 208 identities, 6 031 profiles; source root users6 103. Явные acknowledgements: orphan profiles72, accounts without profile2 177. Все raw bindings/normalized values/receipt timestamps сверены; профили отсутствующих UID не выдумывать. Старые metadata counts6 025/8 202 применять нельзя. |
| Password credentials | [CREDENTIAL_STAGE.md](CREDENTIAL_STAGE.md): FULL+FINAL manifest+credential bundle dry-run → stage с новым encrypted receipt → receipt-bound verify | 8 208 credentials; exact UID/status/providers/validSince binding к FULL/raw/profile. Подтвердить archive SHA, отдельный credential archive SHA и plan SHA текущего dry-run. Сохранить wrapping key/configRef: без них SQL ciphertext паролей не восстановит вход. |
| Chats/meetings | [CONVERSATION_PROJECTION.md](CONVERSATION_PROJECTION.md): FULL dry-run → stage с отдельным receipt key → receipt-bound verify | Все семь таблиц и зависимости сверены полностью. Проекция и raw-only acknowledgements ниже. Исторические/неразрешённые записи остаются raw и не превращаются в придуманные связи. |

Conversation normalized counts: `chats=5449`, `chat_members=10898`, `chat_messages=6737`, `meetings=155`, `meeting_members=525`, `meeting_messages=159`, `removed_meeting_messages=67`.

Conversation projection SHA:
`dc729302e7530b085b9690972fd5efe5585bdb870ee9b29501ac128e6e5604e4`.

Dependency SHA:
`c0965e075e6f00bd238921f34e6356e11f5763d913e757b2a9122f32b8d2e6ab`.

Raw-only acknowledgement: documents3 091 /participantEntries314;
reason digest `d354add32157d3ebfa1fc0fb4c3ca11a295394a2b398c43b045e229a4561ac60`.

Это counts подготовленного FULL плана, не утверждение о текущем SQL state. Точный набор proof: `conversation-projection-full-summary-20261001.json` и последующие private stage/verify reports. После каждого этапа сохранить его binding SHA/счётчики/receipt и отдельный успешный readback. Проверка последнего этапа не заменяет S3 readback первого.

При потерянном ответе COMMIT или наличии prepared receipt результат неизвестен. Не удалять receipt и не повторять stage автоматически: открыть новое соединение и запустить verify того же источника/receipt. Raw importer сообщает `commit_unknown` и требует полный readback назначения. Несовпадение означает остановку и разбор, а не очистку quarantine/таблиц. После committed данных current five grants не позволяют DELETE rollback; не добавлять его автоматически.

После всех readback требуется controlled login прежним паролем, просмотр собственного профиля/фото и исторического чата/встречи, isolation между двумя аккаунтами и подтверждение администратора. Читаемые строки SQL и test vector сами по себе не подтверждают работающий вход или законченный переезд. Не удалять Firebase до final sync и подтверждённого cutover/rollback порядка.

## Проверка существующих deploy scripts

`backup-mysql84.sh`: пароль через private option-file descriptor, TLS VERIFY_IDENTITY, `--single-transaction --quick`, `--no-tablespaces`, GTID OFF и streaming age encryption; plaintext SQL не пишется на диск. `restore-mysql84.sh` сначала целиком расшифровывает/проверяет age stream и SHA, требует target `clrs_staging` без единой таблицы. Это другой restore path: на нынешнюю schema42 он намеренно откажет. DDL restore не атомарен; при ошибке возможна частичная база, автоповтор запрещён.

Исправлено `--skip-disable-keys`: mysqldump default `--opt` иначе генерирует `ALTER TABLE ... DISABLE/ENABLE KEYS`, а current five grants не включают ALTER/INDEX. Подготовленной InnoDB schema42 эти ALTER не нужны; fake-client test проверяет flag. TRIGGER по умолчанию включён: для фактических triggers нужны TRIGGER, для views SHOW VIEW. Проверенная source schema42 описывает только base InnoDB tables, без triggers/views; отсутствие таких объектов в реальном target нужно подтвердить до выбора `--skip-triggers`, чтобы не потерять позднее добавленные объекты. `--no-tablespaces`/single-transaction/GTID OFF избегают PROCESS/LOCK TABLES/RELOAD требований соответствующих опций. Основания: [MySQL mysqldump](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html), [ALTER TABLE privileges](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).

В обычном PATH отсутствуют `mysqldump`, `mysql`, `age`, `aws`, `node`; найден `/usr/bin/openssl`. Для фактического backup/restore ниже MySQL8.4 и age подготовлены в отдельном приватном каталоге без глобальной установки. Node22 есть в `work/toolchains/node-v22.23.2-darwin-arm64/bin/node`; проектные SDK доступны его runtime. Shell scripts требуют Oracle MySQL8.4-compatible client tools, age и стандартные bash/stat/mktemp/date/cut/mv/rm/wc; Media scripts дополнительно AWS CLI + Node с SDK. Наличие этих программ на Timeweb здесь не проверялось.

`backup-media.sh` не является encrypted FULL restore proof: он требует отдельный versioned backup bucket и versioning обоих bucket, выполняет `aws s3 sync` текущих объектов без authenticated manifest/каждого content SHA. Source deletion не удаляет старую копию; source version history и единый момент SQL+S3 не фиксируются. Env проверяется менее строго (допускается group-read); секреты всё равно хранить0600. Нужны ListBucket/GetBucketVersioning на обоих bucket, GetObject исходных и PutObject целевых; privacy checker требует GetBucketAcl/GetBucketPolicy и чтение bucket control-plane Timeweb. Multipart copy с default copy-props может дополнительно требовать GetObjectTagging/PutObjectTagging. Основание: [AWS CLI sync](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html). Нынешний один private bucket и роль для него не доказывают эти права на другой bucket. Второй bucket/Versioning/новые ресурсы здесь не создаются; текущий безопасный recovery set — проверенный зашифрованный FULL выше.

Фактический `mysqldump 8.4.4` также отклонил `--connect-timeout=5`: эта опция доступна клиенту `mysql`, но не `mysqldump`. В backup она удалена; restore использует клиент `mysql` и не менялся. Вызывающая backup задача должна задавать общий deadline и запас диска; защищённый локальный runner ограничивает операцию 600 секундами, ciphertext 1 GiB и резервом 2 GiB. Узкий regression проверяет отказ неподдерживаемой опции без публикации архива и успех исправленного вызова.

Фактическая проверка backup 2026-10-01: MySQL 8.4.4-4, существующий SELECT-only пользователь, TLS с CA и проверкой hostname, 42 из 42 base tables — InnoDB. После удаления неподдерживаемого параметра за 15,926 секунды создан ciphertext 114 834 764 байт, SHA256 `51fed4bed42b909f303e859d088972c05d44473e0e555ef3d45c0924747a60e1`. Полностью потреблённая расшифровка age завершилась exit 0; bounded stream подтвердил staging marker, 42 CREATE TABLE / InnoDB, 122 INSERT statements и завершённый dump footer, без plaintext файла. Ключ и архив имеют 0600, каталог 0700. Проверка SQL формы сама по себе не выполняет restore; следующая отдельная проверка ниже подтверждает реальное локальное восстановление. Привязка внешних wrapping keys и private S3 остаётся отдельной проверкой.

Реальный локальный rollback drill 2026-10-01 выполнен на официальном MySQL 8.4.4 для arm64 / Ventura, без глобальной установки. Дополнительные verified binary bottles — 119 752 128 байт, четыре primary formula lookups. Новый datadir 0700, только private Unix socket: `skip_networking=1`, `mysqlx=OFF`, активных TCP sockets у сервера — 0. Тот же ciphertext через `age -d | mysql` успешно импортирован в новую локальную `clrs_staging`; оба процесса завершились exit 0. Подтверждены 42 InnoDB tables, 66 foreign keys и 66 полных composite anti-join проверок без orphan rows. Один SELECT-only TLS aggregate к Timeweb подтвердил одинаковые row counts всех 42 таблиц, namespace source и целостность UID/scheme/password ciphertext/salt/parameters для всех 8 208 credential rows. Proof SHA256 `88cd0ed7678d4832ca0a5de7a3292fff12c3f753d7e486486694b7c3004cbadd`. Сервер остановлен; private datadir 427 365 898 байт сохранён. Это actual MySQL restore proof, но local root не доказывает будущий DDL restore ограниченной ролью Timeweb; S3 bytes, wrapping keys, final Firebase delta и cutover отдельно. Timeweb writes / grants при drill — 0.
