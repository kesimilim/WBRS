# Timeweb: чистая проверка публичной видимости профиля

`server/timeweb/python-stand/profile_visibility.py` содержит только evaluator и
маленькие структуры входа/решения. HTTP-маршрута, флага включения, SQL, записи в
профили, обращения к Firebase или облаку здесь нет.

## Проверенные источники и границы

- `lib/presentation/screens/list_of_users/profiles_list.dart`: поиск запрашивает
  **явный** `status == 'active'`, исключает текущий UID и применяет возраст,
  страну/регион, пол, группу и сортировку активности отдельно.
- `lib/service/invisibility_state.dart`: два существующих написания
  `isUnVisible`/`isUnvisible` связаны через OR. Без срока активный флаг означает
  бессрочную невидимость; срок строго позже `now` означает временную. Равенство
  сроку уже считается истечением. Сам срок без активного флага не включает режим.
- `lib/service/profile_delete_service.dart`, `legacy_own_profile.py` и текущие
  клиентские проверки исключают `deleted`/`blocked`; сохранённые поля нельзя
  оживить только через текущий активный аккаунт.
- `server/timeweb/project-profiles-core.mjs` переносит отсутствующий исходный
  `status` в `accounts.lifecycle = 'active'`. Это **не** доказательство допуска
  в старый поиск. Проекция не переносит режим невидимости: `invisible_until`
  первоначально NULL. `legacy_raw` остаётся исходным typed Firestore envelope.
- `tool/security/firestore.strict.rules` явно является локальным design fixture,
  ограничивает чтение users чужим пользователям и не доказывает работу поиска в
  production. Сохранённый локально deployed rules snapshot от 2026-10-02 содержит
  общее разрешение для signed-in; он также не является проверкой приватности.
  Evaluator не представляет ни один из этих файлов как production privacy proof.

## Контракт

`evaluate_profile_visibility` принимает `VisibilityAccount` для actor и target,
отдельный `current_actor_uid`, `CanonicalVisibility`, `legacy_raw`, **явный**
trusted `origin='legacy'|'native'` и `now` с часовым поясом. DB-флаги — точные
`int` 0/1; bool, строка, NULL и неизвестный lifecycle не преобразуются автоматически.
UID должны совпадать буквально. Actor A после смены current actor на B, отключённый,
blocked/deleted actor или target, собственный профиль и конфликт UID дают отказ.

Legacy требует полный исходный envelope `{fields, createTime, updateTime}` и
явный `status: {stringValue:'active'}`. Нет новых lifecycle aliases. Отсутствующие
`registrationStatus`, `deleted`, два флага невидимости и срок сохраняют семантику
старого предиката; корректный `{nullValue:null}` также означает отсутствие.
Неизвестный непустой registrationStatus получает отказ: для него нет доказанного
значения в источнике. Допускаются отсутствие, пустая строка и exact `active`;
exact `blocked`/`deleted` всегда исключаются.

Обёртки должны иметь ровно один правильный Firestore тип. `booleanValue` принимает
только Python bool. Некорректный флаг или срок даёт отказ даже при другом false
флаге. `timestampValue` требует UTC RFC3339 с Z, допустимы исходные наносекунды.
Для старого `stringValue` срока принимается только ISO с явным Z/offset; локальная
дата без зоны не является UTC-доказательством и получает отказ. Активный флаг с
отсутствующим/NULL сроком остаётся бессрочно скрытым. Canonical NULL никогда не
отменяет retained невидимость. Непустой canonical срок у legacy даёт
`visibility_authority_unmapped`: текущая проекция не определила precedence для
будущей native visibility mutation.

Native — отдельная ветка: нужны trusted native origin, фактический `legacy_raw = {}`
и **оба** canonical флага `profile_details_saved = 1`, `registration_complete = 1`.
Отсутствующий raw, пустой legacy envelope или выбор origin клиентом этого не
заменяют. Canonical UTC-срок временной невидимости проверяется отдельно. Здесь
нет механизма покупки/бессрочной native невидимости; его перенос потребует
собственного authoritative состояния. Ветка не завершает регистрацию, не ставит
флаги и не обходит требование трёх фотографий.

Результат — immutable `VisibilityDecision(visible, reason)` с фиксированными
причинами. Он не содержит UID, email, баланс, роли, raw, private DTO, фотографии
или произвольные тексты ошибки. Это внутренняя проверка eligibility, а не public
profile payload. Вход не изменяется; JSON source ограничен 128 KiB, повторные
JSON-ключи и malformed envelope отвергаются.

## Что ещё нужно полноценному native people/Home

Будущий маршрут должен заново проверить access token/current actor и lifecycle
в той же read transaction; evaluator не проверяет токены. Нужны отдельный allowlist
public DTO, возраст/географические/групповые фильтры, стабильная пагинация, доступность
профиля/порядок активности и безопасные media references. `last_online_at`, полное
публичное media-представление и authoritative native invisibility ещё не доказаны
этой правкой. `visible=True` не обещает, что профиль проходит остальные фильтры,
имеет фотографии или доступен через включённый API.

## Локальная проверка

Из `server/timeweb/python-stand`:
`python3 -m unittest -v test_profile_visibility`.
Синтетические случаи проверяют два написания флагов, UTC/наносекундную границу,
бессрочную невидимость, malformed/absent/null, current A/B, disabled/lifecycle,
canonical NULL, отдельную native completion ветку, сохранение raw и отсутствие
private данных в результате. Никаких production read/write или широкого suite.
