# Native own questionnaire completion

Добавлена отдельная own mutation `profile.complete-test.v1`:
`POST /v1/runtime/me/temperament`. Она завершает существующий тест для своей
текущей canonical анкеты. Existing profile edit/full read contracts, schema,
table grants, deployment и значения flags не изменены. Серверные gates прежние:
native auth, внешний operator preview, `CLRS_RUNTIME_WRITES_ENABLED=1` и
`CLRS_RUNTIME_MEMBERSHIP_AUTHORITY=canonical-current-v1`.

## Точный request

```json
{
  "operationId": "12345678-1234-4234-8234-123456789abc",
  "expectedUpdatedAt": "2027-01-15T08:00:00.000001Z",
  "scores": {
    "brown": 20,
    "red": 5,
    "blue": 5,
    "white": 5
  }
}
```

Body содержит ровно эти keys, scores — ровно четыре именованных values.
`operationId` использует existing UUID contract; `expectedUpdatedAt` — existing
валидный UTC microsecond stamp из current full-profile GET. Каждый score —
exact int 0..20, не bool/string/float; сумма не меньше 20. Existing questionnaire
содержит 80 отдельных checkbox statements, по 20 в каждом блоке, поэтому
максимальная сумма 80 следует из этих четырёх границ. Утверждения о ровно 20
selected answers нет: пользователь может выбрать 20..80.

UID, group, flag, balance/role/media/geography/client SQL не принимаются.
Query parameters, неизвестные keys, неверная форма/score/stamp → generic `400`
до открытия SQL transaction. GET этого path → `405`; disabled gates → `404`.
Source UID берётся только из native identity, подтверждённого store.

## Группа и readiness

Сервер вычисляет группу по точной существующей методике
`lib/core/utils/temperament.dart`, не принимает group от клиента. Primary ties
разрешаются в порядке white → blue → red → brown. Для второго по величине
distinct score применяются прежние отдельные tie orders:

| Primary | Secondary tie priority |
|---|---|
| brown | white → blue → red |
| red | white → blue → brown |
| blue | white → brown → red |
| white | brown → blue → red |

Если следующего положительного distinct score нет, возвращается pure group.
Например, `{20,20,0,0}` → `красная`, `{20,5,5,5}` → `коричнево-белая`,
`{5,5,5,5}` → `белая`. Изменения методики этим шагом не выполняются.

Profile row выбирается по primary key + exact binary UID,
`LIMIT 1 FOR UPDATE`, тем же bounded SELECT и strict typed decoder, что current
full-profile read. Все source поля сначала проходят валидацию. Порядок решения:

1. Нет profile row → `404`, `result:{error:profile_not_found}`.
2. Stamp отличается → `409`, `result:{error:profile_changed,updatedAt:<current>}`.
3. `isRegistrationEnd=true` либо recognized primary group → `409`,
   `result:{error:test_already_completed,updatedAt:<current>}`. Повторный тест
   другой операцией не переписывает сохранённый результат.
4. Нет реальных canonical details или подтверждения прежнего сохранения → `409`,
   `result:{error:profile_incomplete}`.
5. Иначе выполняется собственное completion.

Readiness требует source непустой trimmed fullName, nonnull int age и непустые
source pol/about/hobbi по existing historical details predicate. Дополнительно
нужен `profileDetailsSaved=true` **или** исходный details fallback в приватном
retained `profiles.legacy_raw.fields`. `profileDetailsSaved` в пустой/неполной
canonical анкете сам не разрешает completion. Legacy short
text сохраняет допуск; trim применяется только к fullName, остальные три
строки используют exact `!= ""` совместимость прежнего gate. Новые требования
к geography или длине changed editor fields не придумываются.
Malformed source/stamp/typed fields → `503 service_unavailable`, не новая
регистрация и не client invalid_request.

Private source proof выполняется bounded Boolean SELECT по тому же own UID,
пока текущая profile row уже locked `FOR UPDATE`. Каждый original required
field должен быть объектом ровно с одним Firestore type key. Original fullName,
pol/about/hobbi — `stringValue` с прежними source bounds; fullName проверяется
по точному whitespace-набору Python `.strip()`, остальные строки только по
`!= ""`. Original age принимает прежние формы `integerValue`/`stringValue`
с ASCII digits длины1..3 и значением0..150 либо `doubleValue` с finite JSON
numeric INTEGER/DOUBLE значением0..150. `nullValue`, typed-null, лишние tags,
строковые `NaN`/`Infinity`, неверные bounds или отсутствие original fields не
подтверждают readiness. Type guards/CASE предшествуют numeric CAST. Current
canonical age независимо должен быть валидным int0..130.

Importer `server/timeweb/project-profiles-core.mjs` сохраняет исходный typed
Firestore документ в `legacy_raw`; native signup
`server/timeweb/python-stand/native_pending_account.py` создаёт profile с flags0
и default `legacy_raw={}`. Existing edit8 не пишет ни этот archive, ни saved
marker. Поэтому заполнение новой анкеты через edit8 не заменяет обязательное
сохранение регистрации с3фото: даже при current fallback `onboarding:test`
completion возвращает durable `409 profile_incomplete`. Историческая анкета
с доказанным original fallback и реальными current details сохраняет доступ.
Raw archive не читается через connector, не выдаётся в DTO/receipt и не пишется.
Current public onboarding и контракт geography этим proof не изменяются.

## Запись и точный response

В одной existing bounded native transaction меняются только:

- `primary_group` — server-derived recognized group;
- `test_result` — exact object `{scores:{brown,red,blue,white},primaryGroup:<derived>}`;
- `registration_complete` — `1`;
- `updated_at` — strictly increased existing CAS stamp.

UPDATE дополнительно содержит exact owner/CAS predicate. Повторное bounded
чтение подтверждает новую группу/flag/stamp и неизменность остальных typed
полей; отдельный bounded JSON equality proof подтверждает `test_result`, не
возвращая raw answers. Other profile columns, secondary group, raw archive,
media/photos, roles, balance и account state не пишутся. Нет новых permissions:
existing profiles SELECT/UPDATE и idempotency receipt rights достаточно.

Success имеет HTTP `200` и существующий receipt envelope:

```json
{
  "operation": "profile.complete-test.v1",
  "operationId": "12345678-1234-4234-8234-123456789abc",
  "requestHash": "<existing exact-request SHA256>",
  "state": "committed",
  "replayed": false,
  "result": {
    "uid": "verified-own-uid",
    "primaryGroup": "коричнево-белая",
    "isRegistrationEnd": true,
    "onboarding": "search",
    "updatedAt": "2027-01-15T08:00:00.000002Z",
    "profileAuthority": "canonical-current-v1"
  },
  "entityRevision": null
}
```

Result содержит ровно эти шесть keys; raw test JSON/scores/email/roles/financial
fields/media URLs не выдаются. Source полный профиль после success перечитывается
через current full-profile GET. Receipt `state:committed` означает сохранённое
решение: при HTTP `404/409` result содержит error и **не** утверждает завершение
теста. UI признаёт completion только по успешному typed result и текущему session lease.

## Lookup и неизвестный результат

Original payload `{expectedUpdatedAt,scores}` передаётся existing store без
нормализации для immutable request hash/receipt. Native access proof, session
version/expiry/revocation/account checks выполняются в той же transaction до
и после action. CAS или already-completed refusal тоже получает своё receipt.

`GET /v1/runtime/operations/profile.complete-test.v1/<UUID>?requestHash=<SHA64>`
использует существующий own authenticated READ ONLY lookup. При unknown COMMIT
POST возвращает `503 outcome_unknown`; клиент удерживает исходный operationId,
payload/hash и выполняет lookup вместо replacement/resend POST. Отсутствующий
receipt не разрешает повторную запись. Replay той же UUID с тем же payload
возвращает первоначальное решение; другой payload/hash → `409 operation_conflict`.
Все lookup/replay заново проверяют current native account/session.

## Проверка и граница результата

7/7 новых scoped tests прошли на bundled Python3.12.14 через реальный
`RuntimeMutationStore` и существующие MySQL-shaped no-TCP connector fixtures:
legacy short details transition, classifier primary/secondary ties, exact
score/body bounds, missing/incomplete/corrupt sources, CAS/already-completed/
other-device no override, original receipt replay/hash conflict, lost COMMIT ACK
с успешным lookup, disabled actor и rollback при неверном final JSON proof.
Readiness cases также подтверждают refusal для заполненного native source `{}`,
allow для сохранённого canonical marker, historical integer/string/double age,
отказ при typed-null/лишних tags/строковом NaN и whitespace-only original name.

```sh
# cwd: server/timeweb/python-stand
/Users/anaakovleva/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  -B -m unittest -v test_runtime_temperament.py
```

Это backend source/transaction contract. Native questionnaire consumer/UI,
durable client intent, device acceptance и живое deployed выполнение ещё не
подтверждены. Cloud/API/DB/network requests, schema/permissions changes,
deployment/flags activation и платёжные ресурсы в этом шаге не выполнялись.

### Последующий адресный SQL proof 02.10.2026

Выражение eligibility из текущего `_legacy_details_proof_select` выполнено
на реальной Timeweb MySQL `8.4.4-4` с девятью синтетическими JSON payloads.
FROM заменён на parameterized derived table; настоящая таблица profiles не
использовалась. Все девять ожидаемых решений совпали: integer/string/double
legacy age, пустой native source, дробная строка, NaN, отсутствующий about и
Unicode whitespace имени. READ ONLY transaction, 0 записей, 0 прочитанных
пользовательских строк, TLS с проверкой CA и имени сервера. Это проверяет
совместимость SQL с MySQL, а не вход или анкету живого пользователя.

Текущая серверная версия опубликована на закрытом stand в GitLab
`caed7fbe12465905d6839f24b819ac2e94668641`; native flags не включены. Клиентская
анкета и её отдельные проверки описаны в `TIMEWEB_NATIVE_TEMPERAMENT_UI.md`.
