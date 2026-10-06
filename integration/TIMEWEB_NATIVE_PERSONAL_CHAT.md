# Личный чат из текущей public анкеты Timeweb

Подготовлена серверная операция создания или получения одного личного чата для пары текущих UID. Это source implementation с адресными локальными проверками. В рамках этого этапа не выполнялись DB reads/writes, DDL, GRANT, cloud calls, deploy, включение flags или изменение Flutter/auth client. Этап не означает завершение переезда.

## HTTP и результат

`POST /v1/runtime/personal-chats` принимает только:

```json
{"operationId":"12345678-1234-4234-8234-123456789abc","targetUid":"synthetic-peer"}
```

`operationId` — lowercase UUID по существующему HTTP contract. Автор берётся только из текущей native access session (`Bearer na1...`); UID автора, `chatId`, имя или `publicProfile` из body не принимаются. Firebase token, refresh token и произвольные дополнительные keys отвергаются. Авторизация предшествует чтению body.

Операция `chat.open-personal.v1` использует тот же `RuntimeMutationStore`, transaction/idempotency pool и прежние gates: `CLRS_RUNTIME_WRITES_ENABLED=1`, `CLRS_RUNTIME_MEMBERSHIP_AUTHORITY=canonical-current-v1`, существующий operator preview guard и native authentication. Отдельный flag не добавлен; отсутствующие существующие gates возвращают 404.

Первая успешная вставка возвращает HTTP 201; найденный существующий чат — HTTP 200. Существующий operation envelope содержит `operation`, `operationId`, `requestHash`, `state`, `replayed`, `entityRevision`. Новый `result` имеет ровно четыре поля:

```json
{"chatId":"tw-pair-<sha256>","peerUid":"synthetic-peer","created":true,"chatRevision":0}
```

При нахождении уже импортированного чата возвращается его настоящий `chatId`, `created=false`, текущая revision. Его ID не заменяется вычисленным ID. Повторная выдача той же операции сохраняет исходный `created`, а `replayed=true` описывает повторное получение receipt. Старые send/read response DTO и request hashes не изменены.

Self-chat и неправильный UID дают 400. Отсутствующая, скрытая, disabled/blocked/deleted или неполная native анкета любого участника даёт общий `person_unavailable` без профиля/содержимого source. Повреждённая текущая membership даёт `chat_unavailable`. Неизвестные права, отсутствующая гарантия уникальности, malformed receipt и инфраструктурная ошибка дают 503 с прежним безопасным HTTP error. После изменения текущего доступа replay/lookup может вернуть 401 вместо сохранённого ответа; receipt не предоставляет обход авторизации.

## Текущая authority и видимость

`runtime_personal_chat.py` берёт две exact canonical строки `accounts` + `profiles`; JOIN и UID predicate дополнены binary equality. SQL читает только UID, account disabled/lifecycle, два completion flags, canonical `invisible_until` и bounded retained raw. Имена, email, фото, деньги, текст анкеты и nullable public DTO для операции не нужны. Пустое или NULL имя сохраняется как неизвестное и не подменяется догадкой.

Оба аккаунта должны быть текущими active, disabled=0. Обе анкеты проверяются существующим frozen `evaluate_profile_visibility` по тому же правилу, что directory/public reader. Проверка симметрична: каждый участник должен быть видим другому; это внутренний eligibility check, который не выдаёт и не авторизует чужую session.

Trusted stored raw `{}` означает native origin и требует обоих canonical completion flags=1. Origin не выбирается параметром клиента. Непустой raw проверяется как legacy: exact active source status, правильные typed fields/source identity, retained hide/deletion/block flags и UTC expiration. Canonical NULL не отменяет скрытие из source. SQL не возвращает raw, если он не OBJECT или больше 131072 bytes; decoder также ограничен размером и отклоняет duplicate JSON keys. Malformed raw закрывает операцию. Успешный profile-details backfill сам по себе не доказывает public eligibility.

## Уникальность, locks и транзакция

Source schema `server/timeweb/db/001_initial_mysql84.sql` уже содержит `chats_pair_uq(uid_low,uid_high)`, `PRIMARY KEY chats(chat_id)` и `PRIMARY KEY chat_members(chat_id,uid)`. Новая DDL не требуется. Пара сортируется по exact UTF-8 bytes; новый ID — `tw-pair-` + SHA256 доменного префикса `clrs-current-personal-chat-v1\0` и canonical JSON `[uid_low,uid_high]`. Он не зависит от operation ID, порядка участников, имени или email.

Каждая action сначала блокирует exact пару `chats` и её membership rows; для новой пары — также candidate membership range. Затем один bounded metadata SELECT проверяет только эти три конкретных indexes: ожидаются ровно пять parts, unique/full-column, без prefix и с `utf8mb4_0900_bin`. LIMIT 6 обнаруживает лишний index part. Metadata proof не берётся из env. Это проверка текущей операции, а не scan всей schema. Locks таблиц удерживают metadata contract до конца транзакции.

После этого shared locks защищают текущие account/profile authority обеих сторон. Существующий чат требует ровно двух exact members, без постороннего/duplicate UID, корректные read counters <= last sequence и notifications 0/1. Archived UI state не считается revocation; настройки существующего чата не меняются.

Новая вставка состоит из одного `chats` row и ровно двух `chat_members` rows в одной существующей SERIALIZABLE transaction вместе с idempotency receipt. Все значения параметризованы. New chat имеет fresh UTC created/updated timestamps, last_sequence=0, revision=0, raw `{}`; участники — read_through_sequence=0, notifications_enabled=1, archived_at=NULL. После inserts выполняется повторное чтение exact пары/members до COMMIT. Нельзя автоматически «дополнить» повреждённый существующий чат, переписать участников или использовать UPSERT для обхода конфликта.

Уникальные keys предотвращают duplicate conversation/member rows при параллельных operation IDs и при обращении второго участника. Возможный MySQL deadlock/unique conflict откатывает всю transaction и отдаёт bounded failure; автоматического retry нет. Local concurrency fixture сериализует транзакции и проверяет idempotency contract, но не служит доказательством live MySQL deadlock/SQL parser/permissions.

Action не создаёт сообщения, notification/outbox/user_events или связи с медиа. Existing messages, settings, profiles, retained legacy documents, roles, balances и source archive не изменяются.

## Точный permission contract

Общий `strict-tables-v1` validator и его grants остаются прежними. Эта модель даёт `SELECT,UPDATE` на `chats` и `chat_members`, поэтому может найти существующий чат, но создание отсутствующей пары закрыто до chat INSERT; receipt reservation откатывается. Старые send/read продолжают работать.

Текущий `provider-database-v1` допускает ровно существующий `SELECT,INSERT,UPDATE ON clrs_staging.*` + global USAGE, без смешанных/лишних grants; этого достаточно для данной action. Store заново проверяет выбранную модель и SHOW GRANTS каждой transaction. Операция не расширяет эту роль и не выбирает её вместо владельца.

Если нужен отдельный узкий technical account для personal-create, минимальное будущее расширение относительно strict map — только `INSERT` на `clrs_staging.chats` и `clrs_staging.chat_members`. Для безопасного применения понадобится отдельная reviewed permission-model label/parser, принимающая полный прежний exact table map плюс эти два INSERT. Этот parser и GRANT здесь не реализованы. Нельзя просто добавить INSERT к нынешнему strict account: strict validator намеренно откажет расширенным grants, что закроет также прежние операции. SELECT на `mysql.*`, DELETE, DDL и новая БД не нужны; information_schema query ограничен metadata доступных текущей роли таблиц.

## Receipt и неизвестный COMMIT

Request hash вычисляется существующим store по canonical JSON `{"targetUid":"..."}`. Повтор с другим target под тем же actor/operation/operationId возвращает conflict. Receipt и chat/member inserts фиксируются атомарно; потеря acknowledgement COMMIT возвращает прежний `outcome_unknown`, без automatic retry.

Разрешённое reconciliation — свежий authenticated `GET /v1/runtime/operations/chat.open-personal.v1/<operationId>?requestHash=<lowercase-sha256>`. Lookup читает receipt в новой READ ONLY transaction и повторно проверяет обе текущие account/profile authority, exact pair и membership. Новый opt-in `response_guard` получает также сохранённый response: malformed/пустой reply, foreign peer/chat ID, удалённый либо заменённый чат не могут выдать старый ID. Общий hook сохраняет прежние четыре аргумента для send/read guards. Более новая chat revision допускается, более старая — отказ.

`state=committed` после проверки даёт исходный ответ. `state=not_found` не создаёт чат. После unknown COMMIT клиент удерживает исходный operationId/requestHash и сначала reconciles; новая operation ID или слепой повтор не выводятся из 503. Позднее скрытие/disable/removal блокирует выдачу даже уже committed receipt.

## Адресная проверка и оставшаяся граница

`test_runtime_personal_chat` — 16 локальных synthetic tests PASS: atomic create, reuse импортированного ID, reversed actors, exact ordering, self/hidden/disabled/incomplete/malformed/oversize source refusal, unique/index prefix/collation refusal, strict failclosed, rollback при member insert failure, same request replay/conflict, неизвестный COMMIT committed/not_found, fresh readonly reconciliation, later visibility/membership rejection, empty/foreign/replaced receipt ID refusal и HTTP body/auth/default-off contract. В этом же наборе проверено прежнее send/read с replay на unchanged strict grants. Дополнительно 4 прежние HTTP/receipt regressions PASS: send/read/profile forwarding, shared read/send pool, reconciliation hash/identity и generic receipt replay/conflict. Добавленный oversize refusal проверен отдельным повтором одного адресного case. Нет реальных UID/данных, TCP или credentials в fixtures.

Следующая проверяемая граница — root review source diff, затем отдельно разрешённый controlled сценарий A/B на deployed runtime с текущими authority/gates/role: первая action, повтор из обеих сторон, один exact chat + два members, reconciliation и later disable/hide refusal. Этот документ не подтверждает такую live проверку, не включает routes и не объявляет full cutover завершённым.
# Current target denial and declared failure receipts

After a successful personal-chat receipt, a current target visibility or membership denial raises `PersonalChatAccessRejected`. HTTP returns `404 {"error":"person_unavailable"}` without an authentication challenge. The actor's valid native session remains valid; a disabled/expired/revoked actor still follows the existing 401 path. The success receipt is not rewritten or emitted after target access fails.

An original error-only `person_unavailable`/`chat_unavailable` result remains a committed declared failure. The replay guard validates this explicit error allowlist and returns, while the store retains its before/after current actor checks. This lets a client acknowledge a known rejection without treating it as an unknown COMMIT or issuing an automatic retry. A later thin current-target refusal of a previously successful receipt does not acknowledge a pending intent.

Three targeted checks passed: retained original target failure; current hide/member denial versus disabled actor; POST and original lookup returning target 404 without a WWW-Authenticate/logout signal. No live user requests or writes were made by these synthetic cases.
