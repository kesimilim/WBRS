# Native own geography edit

Добавлена отдельная операция `profile.edit-geography.v1` и
`POST /v1/runtime/me/geography`. Она меняет страну и регион своей уже сохранённой
canonical анкеты. Старый profile editor GET/POST contract с восемью полями
сохранён. City/language, onboarding/test/group, media, roles, balance и raw archive
не входят в эту запись.

Сервер использует существующие native auth/operator preview/runtime gates,
transaction pool и права profiles SELECT/UPDATE + receipts. Schema, grants,
environment/flags и deployment не менялись.

## Catalog source

`server/timeweb/python-stand/geo_catalog.json` — точная побайтовая копия
существующего `assets/geo_catalog.json`. Root asset не изменён. Version `2`,
56 countries, непустой список exact regions у каждой страны; cities в asset нет.
SHA-256 обеих копий:

```text
6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05
```

`runtime_geography.py` читает только fixed соседний файл, до 65536 bytes, и
сначала проверяет exact pin, затем version/shape/uniqueness/bounded strings.
Missing/changed/malformed catalog → generic `503 service_unavailable` до SQL.
Проверенный локальный catalog кешируется в процессе. Remote source, request
path/env override или HTTP catalog не принимается. Country name выводится
сервером из `countryCode`; segment/languageGroup из asset ничего не авторизуют
и в этом шаге не пишутся. Existing client `GeoCatalog` использует тот же root
asset; Russia ordering меняет только порядок вариантов, не membership.

## Exact request and result

```json
{
  "operationId": "12345678-1234-4234-8234-123456789abc",
  "expectedUpdatedAt": "2027-01-15T08:00:00.000001Z",
  "changes": {
    "countryCode": "AU",
    "region": "New South Wales"
  }
}
```

Body содержит ровно эти keys; changes — ровно `countryCode` и `region` вместе.
Code — exact uppercase two-character catalog code; region — exact непустая
строка из regions этой страны, в пределах current SQL 191 characters/764 UTF-8
bytes. Код и регион не trim/translate/case-normalize. Empty region не разрешён.
Country/city/language/UID/flags/group/roles/media/balance и неизвестные keys не
принимаются. Неподходящий payload/query → `400` до SQL; GET route → `405`;
disabled existing gates → `404`.

Success HTTP `200` использует прежний receipt envelope (`operation`,
`operationId`, `requestHash`, `state:committed`, `replayed`, `result`,
`entityRevision:null`). Result содержит ровно шесть keys:

```json
{
  "uid": "verified-own-uid",
  "country": "Австралия",
  "countryCode": "AU",
  "region": "New South Wales",
  "updatedAt": "2027-01-15T08:00:00.000002Z",
  "profileAuthority": "canonical-current-v1"
}
```

## Ownership, eligibility and CAS

UID берётся только из native proof внутри existing store; caller не выбирает
чужую строку. В одной bounded transaction профиль читается по primary key и
exact binary UID, `LIMIT 1 FOR UPDATE`, через current full-profile decoder.
Native session/account/version/revocation/expiry proof проверяется до и после
action, как для остальных runtime mutations.

Порядок решения:

1. Нет profile row → `404`, receipt result `{error:profile_not_found}`.
2. CAS отличается → `409`, result `{error:profile_changed,updatedAt:<current>}`.
3. Current completion flag или recognized group разрешают legacy completed
   edit. Либо требуется `profileDetailsSaved=true` вместе с реальными canonical
   details (existing fullName/age/pol/about/hobbi predicate).
4. Blank/new profile, legacy fallback без saved/completed proof или saved marker
   без реальных details → `409`, result `{error:profile_not_ready}`.

Readiness не выводится из новой geography и не меняется ею. Этот endpoint не
создаёт анкеты, не ставит saved/registration flags, не завершает тест и не
заменяет регистрацию с требованием трёх фотографий. Count/media readiness
самим geography endpoint не утверждается; уже завершённые legacy анкеты
сохраняют принятый допуск.

UPDATE пишет только `country`, `country_code`, `region`, `updated_at`, с
дополнительным exact owner/CAS predicate. City/language, completion/saved flags,
primary/secondary groups, test JSON и прочие source данные не пишутся. Final
bounded reread проверяет новые geography values, увеличение stamp, неизменность
всех остальных typed полей и прежний onboarding destination. Source malformed
или неожиданное post-write изменение → `503`, rollback всего action/receipt.
Равные уже canonical values — no-op: stamp сохраняется, decision receipt
завершается. Response не содержит raw/test JSON или финансовых/private/media keys.

## Receipt and uncertain response

Immutable request hash строится из exact исходного
`{expectedUpdatedAt,changes}`, без operationId и без подставленного country.
`GET /v1/runtime/operations/profile.edit-geography.v1/<UUID>?requestHash=<SHA64>`
использует прежний собственный authenticated READ ONLY lookup. Он повторяет
исходные result/status: при `404/409` state `committed` означает записанное
решение об отказе, а не сохранение geography.

Unknown COMMIT → `503 outcome_unknown`. Клиент удерживает исходные UUID/payload/
hash и проверяет receipt, не отправляет replacement/resend POST. `not_found`
receipt не разрешает новую запись. Повтор той же UUID/payload возвращает старое
решение без второго profile UPDATE; другое содержимое → `409 operation_conflict`.
После подтверждения клиент перечитывает current profile: receipt подтверждает
исходную операцию, а более позднее редактирование другого устройства могло
изменить текущие values.

## Verification boundary

10/10 scoped Python tests прошли на bundled Python3.12.14: восемь новых tests
через реальный `RuntimeMutationStore` с существующими MySQL-shaped no-TCP
fixtures и два выбранных прежних editor checks. Проверены exact asset bytes/hash,
страна/регион и server name, сохранность всех non-geo source fields/destination,
eligibility/refusals, CAS/no-op/missing, exact payload/catalog membership,
missing/changed catalog, old editor geography rejection, lost ACK/receipt/replay/
hash conflict, disabled native actor и rollback при source/post-write corruption.

```sh
# cwd: server/timeweb/python-stand
/Users/anaakovleva/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  -B -m unittest -v test_runtime_geography.py \
  test_runtime_profile.OwnProfileEditTests.test_own_update_exact_fields_and_completion_retained \
  test_runtime_http.RuntimeHttpTests.test_editor_get_has_no_body_and_accepts_no_foreign_uid
```

Это локальный backend contract/transaction proof. Deployed/live SQL, native UI/
journal/device acceptance и production cutover этим шагом не подтверждены.
Git/cloud/network/build/deploy/schema/flags и изменения платных ресурсов не выполнялись.

### Последующее развёртывание 02.10.2026

Пять runtime файлов из GitHub `4d8b83d` опубликованы в GitLab commit
`caed7fbe12465905d6839f24b819ac2e94668641`. Перед публикацией сравнены полные
байты прежних и новых редакторов, включая неизменный SHA-256 каталога.
Существующий Timeweb stand 5179 находится ONLINE на этом commit; основной
старый stand остаётся остановленным. Новых ресурсов, прав, schema или
активации native flags не было.

Один закрытый probe после deploy: `/healthz` — 200 `api_draft`, `/readyz` — 503
`migration_incomplete`, unauthenticated geography POST — 404. `readyz` в режиме
preview намеренно не подключается к пользовательской БД; это не доказательство
ошибки соединения. Probe не читает профили и не выполняет записи. Живое
редактирование профиля и полный переход приложения остаются отдельными gates.
