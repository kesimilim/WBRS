# Own full profile read contract — 2026-10-01

Подготовлен отдельный **default-off read helper** `LegacyOwnProfileService.own_profile(verified_identity)` в `server/timeweb/python-stand/legacy_own_profile.py` и подключён fixed GET `/v1/me/full-profile` через existing `LegacyConversationHttp` dispatcher. `LegacyReadApiService(LegacyOwnProfileService, LegacyConversationDiscoveryService)` объединяет собственный профиль и прежние read routes с одним shared base/connector/codec; HTTP factory передаёт тот же existing 32-byte cursor key. `app.py`, existing `profile_store.py`, native_sessions, shared read core, Flutter/UI и APK не изменялись. Live deploy/API/DB/Firebase/S3 requests/writes не выполнялись. Новый source route выключен по умолчанию; прежний `/v1/me/profile` endpoint и его contract не заменены.

## HTTP route и default-off gates

`GET /v1/me/full-profile` не принимает UID/path argument, limit/cursor или любые query parameters. Любая непустая query string, включая пустые separator-only строки, отклоняется `400` **до** authentication/service read. POST возвращает `405`; дополнительный path segment не является route и возвращает `404`.

Existing dispatcher возвращает `404`, пока не выполнены все legacy READ gates: `CLRS_LEGACY_READ_ENABLED=1`, `CLRS_LEGACY_READ_SNAPSHOT_REVIEWED=1`, `CLRS_LEGACY_READ_MEMBERSHIP_MODE=immutable-reviewed-snapshot`. Enabled request каждый раз проходит existing verifier: Firebase bearer → exact `AuthenticatedIdentity`, native bearer → exact `NativeIdentity` и configured native service. Native token никогда не переходит в Firebase fallback. Обычный caller dictionary или UID не является verified identity. Helper вызывается только `own_profile(identity)`, без дополнительных аргументов.

Existing status handling сохраняется: authentication `401`/`429`/`503`, resource rejection `404`, read rate limit `429`, unavailable/internal failure/response overflow `503`; ответы ошибок generic, без SQL/session/source details. Response bounded 262144 bytes; app dispatcher сохраняет `Cache-Control: no-store`. Factory/shared module wiring не включает flags и не доказывает deployed/live доступность нового route.

## Авторизация и источник

Helper наследует `LegacyConversationReadService._read` без расширения прав: verified exact `AuthenticatedIdentity`/`NativeIdentity`, expiry до/после чтения; active accounts `(uid,0,active)`; flags legacy READ enabled + reviewed snapshot + immutable-reviewed-snapshot; source project/database/bucket и configured SHA64; MySQL8.4/clrs_staging/TLS verify-full; strict SELECT-only roles либо явно выбранная provider-database-v1 READ модель; bounded slots/rate/8s absolute deadline/SQL execution limit/256KiB response. READ ONLY transaction всегда rollback/close; нет COMMIT/DDL/mutations.

Источник — **только** `users/{verified UID}`. Метод не принимает target UID/path/table/SQL. Existing `_document` проверяет exact source path/document ID и canonical payload SHA против retained row; optional `fields.uid`, если присутствует, обязан совпасть с owner. Plain caller dictionary/string identity, expired session, disabled/nonactive account, contradictory raw status/deleted/registrationStatus отвергаются без деталей. Role/custom claims из profile не выдаются и ничего не авторизуют.

`sourceSnapshot` — configured reviewed immutable import pin; `profileDocumentHash` — проверенный конкретный raw document digest. Это reuse текущей snapshot authority, **не** повторная проверка целого FULL archive или доказательство live delta freshness на каждом GET. Нужен финальный source sync/authority gate перед production cutover.

## Точный envelope

- `uid`: verified own UID.
- `profile`: typed whitelist map либо `null`, если users document отсутствует.
- `profileExists`: факт наличия retained users document.
- `onboarding`: `registration | test | search`, по правилам ниже.
- `sourceSnapshot`: SHA64 snapshot pin; `profileDocumentHash`: SHA64 либо null.
- `profileAuthority: immutable-reviewed-snapshot`; `accountAuthority: active-local-account`.
- `mediaReady:false`; `readOnly:true`; `unavailableFields`: имена malformed optional UI полей. Missing/explicit Firestore null не маркируются corruption и остаются null; `booleanValue:null`/`stringValue:null` считаются malformed.

Не создавать фиктивную empty profile map при отсутствии документа. Active imported Auth + missing users возвращается как явная регистрация без создания аккаунта/анкеты.

### Typed profile whitelist

| Поля | Тип/граница |
|---|---|
| uid | exact verified UID |
| status, registrationStatus | source string/null; deleted/blocked отказываются, unknown nonempty status fail-closed |
| deleted, isRegistrationEnd, profileDetailsSaved | source boolean/null, strict critical state parsing |
| группа (`группа`), group | string/null ≤191; exact legacy key сохранён; group alias не подставляется в legacy completion marker |
| fullName, region, city | string/null ≤1000 |
| country, languageGroup, countrySegment, pol, rost, relationStatus | string/null ≤191 |
| countryCode | string/null ≤20 |
| about, hobbi | string/null ≤4096 |
| age | source numeric 0..150/null; integerValue/stringValue decimal ages переводятся в int; finite doubleValue сохраняется числом, поскольку старый Flutter predicate принимает num; не округлять |
| deti, online, isUnVisible, isUnvisible | source boolean/null; snapshot `online` не является текущим presence |
| notificationPreferences | nullable map с messages/meetings/sound boolean/null; unknown keys не передаются |
| lastOnlineTS, unvisibleEnd | source timestampValue ISO string/null; malformed/неподдержанный typed source в unavailableFields, timezone не придумывается |
| profilePic, profilePicThumb | nullable opaque media map, **не строка URL** |

Private email/password/token/admin/roles, financial balance, presentedGifts и неизвестные source keys не возвращаются. Своя gallery/images subcollection здесь не читается. Нельзя подать DTO в прежний `SessionService.hydrate` без presenter mapping/отдельной protected balance compatibility: этот helper не обнуляет/изменяет balance и не заменяет платежный backend. Email для self account тоже остаётся отдельным private self identity contract.

### Состояние анкеты без повторной регистрации

Правила соответствуют текущим `core/utils/account_destination.dart` + `compatibility.dart`:

1. `isRegistrationEnd == true` **или** legacy `группа` (trim/lowercase) входит в точные 16 existing groups → search. False/отсутствующие старые flags не отменяют действительный сохранённый group result. Неизвестный group не выдумывает completion.
2. `profileDetailsSaved == true` → test.
3. Legacy fallback: непустое trimmed fullName + распознанный source numeric age + непустые pol/about/hobbi → test. Если эти required fallback поля malformed, возвращается unavailable, **не** тихая повторная регистрация.
4. Реально missing/incomplete данные → registration. Отсутствие новых current-country/photo требований не отменяет старый сохранённый профиль.

Completion flags/legacy group malformed не принимаются за false/null. `group` без исходного `группа` не утверждает completion старого gate; оба поля сохраняются отдельно по этой семантике. Новый Flutter adapter должен использовать envelope onboarding и явные account/profile states, не выводить destination из шести полей старого own-profile endpoint.

## Медиа и границы

Existing media decoder снимает URL/download-token из ответа и возвращает bounded opaque reference, bound to own UID/source pin/document digest/purpose/field. Legacy media остаётся `status:quarantined` + `mediaReady:false`; внешний/неподдержанный avatar — unavailable. Даже gift asset строка не признаётся avatar и не даёт доступ к filesystem. Нет promotion/HTTP lease/public Firebase URLs/S3 URL/upload. Future media service проверяет ownership/authority отдельно; typed media map нельзя передавать в Image.network через toString. Last-known source privacy/time malformed states необходимо уважать через unavailableFields, а не трактовать как новую текущую подписку/visibility.

## Проверка

**5/5 helper targeted synthetic unittest PASS**, Python3.12.14, существующий bundled runtime/cryptography. Проверены 16 точных groups + completed flag + saved-details + legacy fallback/number variants; missing/partial profile/no mutations; wrong identity/UID/disabled/deleted/contradictory flags; private fields and Firebase download token/path non-disclosure/opaque bindings; default-off/source/hash/TLS/exact-role/typed-null failures. SQL — existing fake connector, не живой MySQL proof. Helper suite проверена до дополнительного combined-class/import wiring; payload/helper logic после неё не менялась.

**11/11 HTTP targeted synthetic unittest PASS** после dispatcher изменения: 7 прежних HTTP contracts и 4 новых tests. Новые проверки охватывают default-off/fixed method+path/shared factory, проверку Firebase/native identity на каждом запросе без guessed UID, отклонение всей query string до authentication/read, generic fail-closed при unavailable/wrong identity/oversize. Никакой dependency install/pubget/build/AVD и broad suites, DB/cloud calls или UI/native routing.

```sh
# cwd: server/timeweb/python-stand
/Users/anaakovleva/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  -B -m unittest -v test_legacy_own_profile.py
/Users/anaakovleva/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  -B -m unittest -v test_legacy_conversation_http.py
```

SHA-256 привязка:

- `legacy_own_profile.py`: `8c901c7c8d84a23c75e68e9ceb2128b4d6a4646eb20f13a00d28a9a309984710`
- `test_legacy_own_profile.py`: `266bfff6a457f38503bbd8ad323faf215316a9cee471e39985fa47f10533f987`
- `legacy_conversation_http.py`: `fa6ef6287e7d1ce6044f0cb3a1995597ef42a4a9229d4605fc0c23fc15aa38f8`
- `test_legacy_conversation_http.py`: `61d6dcc6e9cbe6d043c2a445bb23d14486073e17b487661ea233e81a935d3654`
- `legacy_conversation_read.py`: `08188fa133d63ebd4e5db93080941d7d5c687a890ba6212cac4052e5655af1df`
- `legacy_conversation_payload.py`: `00b40b8f5a85e6eac8a145f79271873b96ac42e93735ca3fc7f3c22ab9b90474`

Root next gate: full own DTO presenter/standalone client method и SessionGate compatibility, controlled imported-user onboarding/read isolation proof, финальный source sync/authority gate, затем согласованные deployment/default flags. Новый HTTP source route не выполняет этих шагов. Не включать global native backend только по synthetic helper/HTTP tests.
