# Current own full-profile read

Добавлен отдельный `GET /v1/runtime/me/full-profile` для собственной текущей
анкеты из `clrs_staging.profiles`. Старый `GET /v1/runtime/me/profile` и его
editor/CAS contract сохранены. Новый route не использует immutable snapshot,
`legacy_raw` или `test_result` для получения полей или состояния onboarding.

Route остаётся за существующими gates: `CLRS_RUNTIME_WRITES_ENABLED=1` и
`CLRS_RUNTIME_MEMBERSHIP_AUTHORITY=canonical-current-v1`, existing native auth
и внешний operator preview guard. Новых серверных flags нет; значения flags,
schema, grants и deployment не менялись.

Нельзя передать UID, SQL/path, query parameters или body. GET с непустой query
или body возвращает `400` до авторизации/чтения; POST — `405`. Неизвестный путь
не расширяет собственный route. Firebase/refresh token не принимается.

Сервис получает UID только из существующего `RuntimeMutationStore.read_authenticated`.
Тот же bounded pool открывает `READ ONLY`, `SERIALIZABLE` transaction и проверяет
native access token на locked `device_sessions/accounts` до и после чтения.
Existing disabled/lifecycle/token-version/revocation/expiry/TLS/MySQL8.4/grants
проверки сохранены. Профиль выбирается одной fixed `SELECT ... LIMIT 1 FOR SHARE`
по exact binary UID. Чтение заканчивается rollback/close, без COMMIT или записи.

## Точный HTTP envelope

```json
{
  "uid": "verified-own-uid",
  "profileExists": true,
  "profile": {},
  "onboarding": "registration",
  "profileAuthority": "canonical-current-v1",
  "mediaReady": false
}
```

`profile` содержит ровно поля из таблицы ниже. Для действительно отсутствующей
строки возвращаются `profileExists:false`, `profile:null`,
`onboarding:registration`; пустая анкета не выдумывается. Source NULL сохраняется
для nullable полей; original text и whitespace не переписываются.

| Поля profile | Тип и границы |
|---|---|
| fullName | string/null, до 1000 Unicode characters и 4000 UTF-8 bytes |
| about, hobbi | string/null, до 4096 characters и 16384 UTF-8 bytes; короткий исторический текст сохраняется |
| pol, relationStatus, country, countryCode, region, city, languageCode, primaryGroup, secondaryGroup | string/null, до 191 characters и 764 UTF-8 bytes по current SQL columns |
| age | int/null, 0..130 по existing schema; bool/string/float не преобразуются |
| rost | int/null, 0..300 по existing schema |
| deti, profileDetailsSaved, isRegistrationEnd | bool/null из exact SQL int 0/1; unknown значения не становятся false |
| updatedAt | required existing UTC string `YYYY-MM-DDTHH:mm:ss.ffffffZ`, с проверкой календарной даты |

Текст допускает newline/carriage return/tab и отвергает другие C0 control
characters, DEL и invalid Unicode surrogates. SQL CASE ограничивает text по
characters/bytes до передачи через connector. Отдельный validity bit отличает
oversized source от настоящего NULL. Любое malformed present поле, неверный
stamp/row/validity bit возвращается как generic `503 service_unavailable`, даже
если completion flag или другая часть анкеты могла дать destination. Ошибка
не выдаёт диагностик/source values и не отправляет пользователя повторно в
регистрацию. Existing store ограничивает JSON response 65536 bytes.

Максимальный разрешённый envelope с UID из 191 four-byte scalars, всеми
максимальными text fields, maximal ints и longest onboarding содержит
44843 bytes при фактическом wire `ensure_ascii=False`, оставляя 20693 bytes
до лимита. App encoder и store canonical encoder используют один UTF-8 режим;
escaping CR/LF/TAB/quote/backslash даёт два bytes на scalar и отдельно проверен
на максимальных text lengths. Serialization/budget error в этом GET считается
server content unavailable (`503`), поскольку route не принимает JSON input.

Email, credentials, roles, balance, media URL, `legacy_raw`, `test_result` и
неизвестные keys не выбираются и не возвращаются. `mediaReady:false` не
утверждает готовность фотографии/gallery. Платёжные сервисы не затронуты.

## Onboarding compatibility

Порядок соответствует существующему `account_destination.dart`:

1. `isRegistrationEnd == true` либо `primaryGroup.strip().lower()` входит в
   точные шестнадцать групп из `compatibility.dart` → `search`.
2. `profileDetailsSaved == true` → `test`.
3. Исторический details fallback: непустой trimmed `fullName`, source int `age`,
   непустые source `pol/about/hobbi` → `test`. Новые требования к фото/country,
   двадцати символам или возрасту edit form не применяются к чтению старой анкеты.
4. Действительно missing/incomplete details → `registration`.

Current projection сохраняет исходное legacy `группа` в `primary_group`.
`secondaryGroup` и неизвестная непустая primary group не утверждают завершение
теста. Trim/lowercase используется только для проверки destination; сами
source group strings остаются exact в ответе. Malformed source сначала
отклоняется и не маскируется onboarding fallback.

## Локальная проверка и граница доказательства

13/13 scoped Python unittest прошли на bundled Python3.12.14: десять новых
full-profile tests и три существующих editor/HTTP compatibility checks.
Новые HTTP tests проходят через реальный `RuntimeMutationStore` с MySQL-shaped
no-TCP connector: own UID A/B isolation, token revalidation/disabled/revoked/
wrong UID/version/expiry, no-query/no-body/no-POST/default-off/no Firebase
fallback, missing/null/legacy short text, all sixteen recognized groups,
completion/saved/details fallback, malformed fields и Unicode/response bounds.
Проверены только SELECT/READ ONLY/rollback/close и отсутствие COMMIT/state writes.

```sh
# cwd: server/timeweb/python-stand
/Users/anaakovleva/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  -B -m unittest -v test_runtime_full_profile.py \
  test_runtime_profile.OwnProfileEditTests.test_editor_read_is_own_bounded_and_not_financial_hydration \
  test_runtime_http.RuntimeHttpTests.test_editor_get_has_no_body_and_accepts_no_foreign_uid \
  test_runtime_http.RuntimeHttpTests.test_send_read_profile_forward_exact_self_identity_and_original_payload
```

Это локальное contract/transaction evidence. Живой MySQL, deployment/flag
activation, source freshness/cutover, media, native onboarding writes и device
acceptance этим изменением не подтверждены. API/schema/cloud calls и writes
в этом шаге не выполнялись.
