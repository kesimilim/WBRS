# Native public profile photo: association review preparation

Актуальный принятый v2 сохраняет default `strict-v1`: прежние fingerprint, AAD и
receipt semantics не меняются. Только явный `gallery_original_policy="available-originals-v2"`
пропускает gallery `url`, который отсутствует, имеет корректный typed null или
равен пустой строке. Все source documents, включая пропущенные, их payload pins
и полная reviewed последовательность source IDs остаются bound в fingerprint /
context; изменение любого такого evidence инвалидирует prepare/reconcile и
runtime reference. Original `profilePic` остаётся обязательным, а каждый непустой
gallery original требует прежних exact ready-media/owner/provenance proofs.
Malformed, nonempty unmapped, foreign или conflicting evidence отказывает целому
плану; thumbnail/Auth.photoURL/произвольный owned object не становятся original.

Projector и runtime выбирают один explicit policy. Runtime v2 задаётся существующей
переменной `CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY=reviewed-source-document-id-binary-asc-available-originals-v2`;
старое значение `reviewed-source-document-id-binary-asc-v1` сохраняет strict.
Полные прежние associations читаются и в v2, новые leases получают отдельный v2
fingerprint, а старые receipts проверяются через strict reconcile. Принятые source/tests
сохранены в GitHub `bec0a3d`; root подтвердил GitLab `7f880d9` ONLINE за preview
guard и контролируемые реальные association apply/readback. Это ограниченное
подтверждение не доказывает перенос всех фотографий, native login, публичный
доступ или cutover; grants, auth/visibility и private S3 guards не расширяются.
Ранние разделы ниже сохраняют историю подготовки и исходных ограничений; их
формулировки «ещё не подключено» не являются текущим статусом принятого v2.

## Подтверждённый пробел

`server/timeweb/MEDIA_PROMOTION.md` прямо отделяет ready `media_objects` от связей
`profile_photos`. Promotion сохраняет owner/purpose/source path/hash, но не роль
аватара, image ID или порядок. `purpose='profile'` объединяет точные profile и
gallery references, Auth.photoURL и старые chat/author snapshots. Поэтому первый
готовый файл владельца, похожее имя, дата создания или Auth.photoURL не доказывают
его главное фото. В текущем source нет projector/writer `profile_photos`, кроме
schema и smoke fixture; live содержимое таблицы здесь не проверялось.

Existing legacy `/v1/media` использует разрешённый own-profile либо conversation
context и immutable snapshot authority. Он не проверяет native public-directory
visibility и не является публичным native разрешением на другую анкету.

## Новый ограниченный план

`server/timeweb/python-stand/profile_photo_review.py` принимает только private
server-side evidence: exact active account, retained canonical raw, pinned source
root/gallery documents с SHA256, bounded ready-media/storage rows, доказанно полный
gallery input, явные existing associations и при необходимости reviewed ID order.
Все входы только проверяются; они не становятся HTTP authority.

Original avatar выбирается **только** из typed `users/{uid}.profilePic`.
`profilePicThumb`, Auth.photoURL, сторонний URL или готовый файл того же владельца
его не заменяют. Root payload digest должен совпасть с canonical retained raw,
а source document — с exact `users/{uid}`. Existing native raw `{}`, missing/null/
empty original, неполный gallery input или неизвестные existing associations
дают `unchanged`, без кандидатов на запись.

Gallery originals берутся только из точных `users/{uid}/images/{id}.url`.
Каждый source payload/digest проверяется; target image ID обязан помещаться в
существующий `VARCHAR(191)`. Все source URL разбираются целиком только для pinned
Firebase/gs bucket. Query/download token не сохраняется. External/S3 URL,
traversal, wrong bucket, malformed types, дубликаты/конфликты и частичное ready
mapping дают отказ целого плана; basename/substring guessing отсутствует.

Для каждого original требуются exact ready `media_objects` owner UID,
`purpose='profile'`, media ID, immutable imported key, legacy path, MIME, size и
content SHA. Они сравниваются с copied `legacy_storage_objects` source bucket/path,
source/target SHA, size, metadata MIME и copy marker. Дополнительные неподтверждённые
objects не допускаются. Контракт ограничен 50 фотографиями; превышение не обрезается.

Schema `profile_photos` уже представляет original avatar через `is_primary=1`,
`ordinal=0`, optional exact `firebase_image_id` и FK `(media_id,uid)` на media owner.
Если current original существует без отдельного images child, image ID остаётся
NULL. Source child documents не хранят числовой ordinal. Для нескольких gallery
documents требуется явно reviewed последовательность exact image IDs; без неё
план остаётся `unchanged:gallery_order_unreviewed`. Primary всегда идёт первым,
но хронология остальных не придумывается. Duplicate photo paths не объединяются
молча. Already matching existing rows — NOOP, конфликтующие rows не перезаписываются.

План содержит immutable association rows, source/media digest pins и fingerprint.
`summary()` безопасен для логов: только state/reason/counts, без UID/URL/raw/object
key. Полный план приватный, `repr` не раскрывает evidence. **Reviewable не означает
applied, current public eligibility, gallery readiness или разрешение скачать файл.**

Thumbnail pairing пока не проектируется: promotion хранит самостоятельные thumbnail
objects как ready rows и оставляет `thumbnail_key=NULL`; schema не содержит отдельный
thumbnail content hash. Нельзя вписать один лишь соседний key или выбрать thumbnail
по имени. Следующий thumbnail контракт должен связывать exact root/image fields и
полные проверенные ready original/thumbnail records.

## Association projector подготовлен локально

Новый `profile_photo_projector.py` реализует bounded prepare/apply/readback для
одного пользователя и guarded rollback. Live wrapper и настоящие source/role/
journal capabilities ещё не подключены; реальные association writes не запускались.
Из scope не выходят новые `profile_photo_projector.py`, адресный test и эта doc.

SQL `legacy_source` хранит только project/database/bucket, **не archive SHA и не
completion**. Поэтому constructor требует `VerifiedSourceSnapshot`, minted через
обязательный trusted private verifier callback после существующей проверки
completed source/import/readback receipt. Factory связывает pinned archive и
manifest SHA, exact source, immutable receipt digest и completed counts:
auth 8208, Firestore 70486, Storage 6478 / 6932196752 bytes. Completed
`segmented-export-verification-20261001.json` со signed manifest доказывает
authenticated local archive; **local export alone не доказывает staging import**.
Root проверил этот archive/manifest comparison. Дополнительно verifier обязан
проверить уже сохранённый completed import и FULL SQL/S3 readback:

- `current-raw-stage-status.json`: `raw-stage`, `complete`, exitCode 0.
- `current-raw-verify-result.json`: `verify`, exact counts выше, SHA
  `74ec37a851c61397af5aecadb31377327ec1abbee8925a158a54f591539ec2e3`.
- `current-raw-verify-status.json`: `raw-verify`, `complete`, exitCode 0, SHA
  `5f11534b92a0c63157ffdfd2226a6a2001401f7b044f68fad2d62e382b42b9ad`.
- `private-media-readback-ack-20261001.json`: pinned SHA
  `09f1fb45427b0f1e460fea482d5dad9fd5e682263c40051d5dfb49d0214a76fd`,
  `reviewed_verified_full_raw_sql_s3`, связывает exact archive/manifest/source/
  counts и оба verify file SHA. CompletedAt `2026-10-01T00:48:09.484Z`.

Эти файлы находятся вне Git в private recovery set. Здесь прочитаны только
aggregate reports и сверены file hashes; secret key/HMAC не читался. Existing
`media-promotion-core.mjs:143` `verifyMediaReadbackAcknowledgement` проверяет
подписанный полный binding с private HMAC, domain, exact fields, source и pins.
Private wrapper должен связать этот **existing** verifier и authenticated FULL
source verification с callback до minting capability; callback со статусом
`verified_local_full_export` factory отказывает. Новый module не делает эти
проверки за caller и не заменяет их своей декларацией. Ранние failed/partial
full-export proofs не подходят. `consistent=false` сохранён в
capability и encrypted receipts: это completed **archival staged source**, не
final delta/cutover/write barrier. Existing `VerifiedMediaPromotion.require_current`
проверяется отдельно и не объявляется source completion proof.

`ProfilePhotoProjector` принимает отдельные apply `connect` / private verifier и
explicit pinned DNS host. `VerifiedPhotoRecovery` принимает **свой** recovery
`connect` / verifier с тем же host pin; active/closed SQL connections не
переиспользуются. Перед каждым transaction verifier подтверждает actual CA/TLS/
hostname, MySQL8.4, strict `clrs_staging`, socket timeout до двух секунд и fresh
actual grants с digest. Minting capability не является фактическим DELETE witness.
До открытия apply transaction отдельный свежий recovery probe выполняет полный
`_context(uid, reviewed_order)` в WRITE-mode transaction **без DML**, проверяет
exact prepared source/plan/context/rows и заканчивается ROLLBACK. Так проверяется
actual query/lock capability до первого INSERT. Перед COMMIT отдельный READ ONLY
preflight проверяет только fresh TLS/grants verifier и не блокирует associations
повторно: повторный FOR UPDATE из другого connection ожидал бы собственный apply
lock. Source/CAS/full rows перед COMMIT перепроверяются на самом apply connection.

Две честно разделённые private permission models:

- Default `strict-tables-v1`: actual underlying SELECT только на семь таблиц
  accounts/profiles/legacy_source/legacy_documents/legacy_storage_objects/
  media_objects/profile_photos. Apply имеет INSERT и UPDATE только profile_photos
  без DELETE; UPDATE privilege нужен для FOR UPDATE, сам runner UPDATE не
  выполняет. Recovery имеет DELETE только profile_photos без INSERT/UPDATE.
  Иных writes нет.
- Explicit `existing-provider-role`: `underlying_permissions_scope` =
  `existing-approved-provider-database`. Для apply декларируются реальные
  существующие broad privileges clrs_migrate CREATE/REFERENCES/SELECT/INSERT/
  UPDATE на `clrs_staging.*`; DELETE у apply отсутствует. Recovery отдельно
  декларирует полный набор actual существующих provider/database-owner
  permissions, с SELECT/DELETE, без global privileges или GRANT OPTION. Эти
  broad permissions **не объявляются** узкой SQL ролью. Fresh verifier обязан
  подтвердить именно declared underlying rights и enforced private runner.

В обеих models `executed_sql_scope` = `profile-photo-projector-v1`, mode apply /
recovery задан отдельно, `runner_allowlist_enforced` и `fresh_grants_verified`
обязательны. Сам transaction executor принимает только точные текущие constant
SELECT shapes на этих семи таблицах, bounded INSERT shapes в apply либо exact
recorded-row DELETE shapes в recovery и session statements. UPDATE/DDL/другие
таблицы или SQL из caller input не допускаются. Это offline private runner
contract, не native HTTP authority, grant, credential fallback или выдача прав.
Provider adaptation не ослабляет source/CAS/receipt/readback checks.

Реального source/connection/recovery/journal wrapper пока нет; ни strict witness,
ни provider-owner DELETE proof не создавался. Без этих проверок настоящий COMMIT
associations запрещён. Deadline каждой transaction восемь секунд, не более 48
statements; watchdog закрывает SQL connection. Private callbacks проверки/fsync
тоже должны быть bounded: closing SQL не отменяет произвольный блокирующий
callback. Connection factory/config остаются у trusted caller, без новых ролей,
grants или environment loader.

Prepare/reconcile используют SERIALIZABLE READ ONLY/FOR SHARE/ROLLBACK; apply и
rollback — SERIALIZABLE с **mixed locks**: source/account/profile/docs/storage/
media FOR SHARE, только profile_photos FOR UPDATE. Это сохраняет source/context
от concurrent changes и позволяет recovery с SELECT source + DELETE photos
выполнить actual lock contract. Все account/profile UID JOIN/WHERE содержат
indexed equality и binary exact guards. Root document проверяется по hash и full
path, gallery query — indexed collection hash + exact collection, byte document-ID
order и LIMIT51; >50 отказывает без truncation. Caller supplies явно reviewed
source ID order, который должен совпасть с этим query order. Это воспроизводит
plain `.collection('images').snapshots()` из `somebody_profile.dart:97` и
`profile_page.dart:77`; timestamps/chronology не добавляются.
Caller получает **полную** reviewed последовательность IDs из authenticated
completed source inventory/archive, а не только из potentially incomplete SQL
gallery query; otherwise равенство двух неполных списков не доказывает completeness.

Storage/media queries ограничены exact paths из source photo fields; готовые rows
не перечисляются по owner. Existing associations читаются с LIMIT51. Source,
current raw/updatedAt, owner, root/gallery digests и полная ready/storage provenance
сверяются в prepare, перед INSERT, после полного readback и перед COMMIT. Только
empty reviewed association INSERT допускается; exact already matching — NOOP,
конфликтующие rows не overwrite/upsert. Scalar/nullable типы проверяет pure plan.
Missing/native/unknown mapping не создаёт rows. Требование трёх фото для новой
регистрации count этих кандидатов не заменяет.

### Durable receipt и восстановление

Caller передаёт отдельный explicit receipt key и **обязательные** pending-journal
loader / durable persistence callback. Нет environment/file/credential loader в
module. После exact full readback формируется AES-GCM authenticated encrypted
prepared receipt с original UUID, source proof, immutable before/after rows,
context digest и plan fingerprint. Caller обязан сохранить ciphertext в private
encrypted journal/file с fsync **до** возврата matching ciphertext SHA; Boolean
ACK не подходит. Missing/failed callback не разрешает COMMIT. После persistence
полный context проверяется ещё раз перед COMMIT. Это private receipt; наружу
возвращаются только state/reason/counts, private prepare object отдаёт безопасный
`summary()` для отчёта, без UID/path/raw/object key.

Unknown COMMIT закрывает/не переиспользует соединение и блокирует повторный apply.
После restart loader обязан вернуть нерешённый prepared receipt того же пользователя;
его наличие блокирует INSERT до явного receipt-bound reconcile на новом соединении.
Reconcile аутентифицирует ciphertext, source binding и текущий полный context,
проверяет exact before-empty либо exact after и отдаёт `not_committed_verified` /
`present_verified`. Он не пишет, не повторяет INSERT и не очищает durable journal.
Caller отмечает resolution отдельно только по подтверждённому readback.

Guarded rollback допускает только apply receipt с before-empty и точные current
after rows того же пользователя при неизменном context. DELETE содержит exact
recorded media IDs, binary UID/ID guards, ordinal/primary/nullable image-ID guards
и bound LIMIT. Другие owners/добавленные/изменённые rows не удаляются. Полный
after-empty readback и отдельный encrypted rollback receipt связывают original
receipt SHA до COMMIT. Unknown rollback COMMIT тоже reconciles по собственному
receipt; никакого автоматического DELETE retry. Source/media objects и S3 не
меняются. Recovery использует отдельный connection/validator; broad existing
owner rights допустимы только в явно названной provider model через reviewed
allowlist runner. Неподтверждённый actual DELETE доступ не заменяется декларацией
provider/migration rights; настоящий apply запрещён до готового private wrapper
и его реального recovery permission proof.

## Минимальный предлагаемый native media read контракт

Existing native `strict-tables-v1` runtime principal не имеет media/source table
rights; existing five-table legacy media principal не читает `profiles` и
`device_sessions`. Его нельзя использовать как proof native public visibility.
До интеграции нужен явно reviewed **read-only** media transaction contract с
SELECT на ровно `accounts`, `device_sessions`, `profiles`, `profile_photos`,
`media_objects`, `legacy_storage_objects`, `legacy_source` и native token verifier.
Это предложение, не grant template/новый permission flag и не выданные права.
Existing provider database privileges сами по себе не заменяют этот review.

В одной bounded READ ONLY transaction: current token/session/account proof до и
после; byte-exact actor/target; existing strict `profile_visibility.py`; exact
primary `profile_photos` association и ready profile object того же владельца.
JOIN использует indexed equality плюс binary identity comparison. Primary query
ограничена LIMIT 2: отсутствие/неоднозначность fail closed. Key и hashes проверяются
через exact legacy storage/source provenance. Никаких client UID как identity,
client object key или raw URL в response. Native uploads/new object prefixes
этим immutable-import contract не поддерживаются.

После SQL разрешён только existing GET-only `PrivateMediaS3` adapter с отдельными
read credentials, свежими private bucket/type/ACL/policy checks, bounded spool,
полной size/SHA verification. До первых response bytes повторить native session,
account, public visibility и тот же association/object context в новой transaction.
Предлагаемый opaque descriptor — actor/target/association/context/purpose-bound,
с отдельным cursor subkey и сроком **не более 60 секунд**, без S3/Firebase URL или
download token. Private no-store byte lease, закрытие при cancel/disconnect и
ограничение времени/числа downloads обязательны; никакого public bucket/presign.
Mid-stream immediate logout/visibility revocation нельзя заявлять до отдельного
проверяемого streaming policy. HTTP/DTO wiring согласуется после projector и этого
permission/query контракта; текущий `avatar:null/mediaReady:false` сохраняется.

## Адресная проверка

`test_profile_photo_review.py`: 8 pure synthetic cases прошли. Они проверяют
original-only выбор, null/native/unknown NOOP, source/current hash и A/B UID,
source/account unavailable, whole URL/type refusal, ownership/purpose/MIME/size/
hash/copy marker, reviewed gallery ordering, ambiguous/unmapped/bounded inputs,
existing-row conflict и отсутствие изменения входов. Это не SQL apply, S3 bytes,
actual user mapping, live API privacy, promotion activation или device proof.

`test_profile_photo_projector.py`: 12 SQL-shaped synthetic cases прошли через
caller-owned fake connections без TCP. Проверены source/recovery capability
missing/mismatch, source/owner/hash/completeness/order refusal, CAS до INSERT и
COMMIT, exact full readback, обязательная encrypted durable callback, unknown
COMMIT в вариантах present/absent + restart without duplicate INSERT, receipt
tamper/context conflict, exact recorded-row rollback с сохранением другого owner,
later-row refusal и unknown rollback reconciliation. Отдельно проверены честная
broad provider permission declaration, separate recovery connection/preflights,
SQL shape allowlist и recovery permission revocation до COMMIT. Это не actual
MySQL parse, live TLS/role acceptance, fsync implementation, database apply или
user photos. Более широкие наборы не запускались.

Mixed-model case проверяет missing apply UPDATE photo lock capability, actual
recovery association lock refusal до INSERT, полный zero-DML WRITE recovery
probe и отсутствие association queries/locks у второго pre-COMMIT preflight.
Root SQL syntax proofs прежнего frozen source hash сохраняются как **baseline**;
они не объявляются proof изменённых mixed-lock запросов. Новый actual SQL/parser
proof делает root отдельно, без user rows или mutations.

Root подтвердил actual MySQL 8.4 parser для 7 SELECT shapes и INSERT shape через EXPLAIN без ANALYZE/выполнения. Gallery/media/storage/association queries используют существующие scoped indexes; источник — singleton PRIMARY. Данные пользователей не читались, writes/DDL=0. EXPLAIN INSERT первоначально отклонён MySQL1792 внутри READ ONLY; проверен отдельно только EXPLAIN в обычной transaction с rollback, без повторения успешных SELECT checks. Proof связан с projector SHA `1eaa4eafe9af8f2f73220bba72113ef345a5ea6017938a1fb16528188999f2b3`. Реальный apply не выполнялся: текущий `gen_user` имеет права на `default_db`, не на `clrs_staging` (1044), и не является recovery capability. Нужен actual проверяемый recovery доступ для exact записанных association rows перед любым COMMIT.
