# Нативный поиск людей: текущие публичные анкеты

Исходники следующего этапа миграции; **не входят в APK 44**. Деплой, активация,
новая сборка и серверные изменения в этот клиентский блок не включены.

## Рабочий путь и границы

- При существующем `ownProfileEnabled` gate читает собственную canonical-current
  анкету. `onboarding=search` открывает native directory; `test`/`registration`
  сохраняют текущий собственный профиль и прежние честные ограничения.
- Directory → public detail получает новый `GET /v1/runtime/people/{uid}`.
  Directory → собственная анкета/чаты используют тот же `TimewebAppRuntime` и
  защищённый native owner. Кнопка «Люди» возвращает к действующему directory.
  Firebase Home, hydration/globals и создание чатов не вызываются.
- Фон/CLRS/фраза, group avatar-заглушка и карточки повторяют текущую композицию
  ProfilesList; прозрачность новых карточек 20% (`0xCC`). Shared стили неизменны.
  `avatar=null`, `mediaReady=false`: нет придуманных URL/галереи/фото счётчика.
  Null-дети и null-активность остаются «Не указано», без false presence badge.
- Клиент соблюдает frozen `RUNTIME_READS.md`: только поддержанные age, pinned
  country/region, exact `м`/`ж` и 16 compatibility labels; limit 1..30.
  Строки/nullable поля сохраняются целиком; приватные/лишние ключи, неверные типы,
  ordering, media, timestamps и ответы свыше 65536 байт отвергаются.
- Список хранит **одну текущую страницу до 30 анкет**. «Загрузить ещё» явно
  заменяет её следующей страницей, номер показывает это; refresh начинает снова.
  Пустая sparse страница с `nextCursor` сохраняет рабочую кнопку продолжения
  без сообщения об отсутствии результатов; оно выводится только при
  `items.isEmpty && nextCursor == null`.
  Автоперехода нет; отсутствие людей на этой странице не утверждает полноту
  выборки, 5927 eligible профилей или отсутствие скрытых/неполных source rows.
- Cursor закрыт typed DTO, хранится только в RAM, redacted в `toString`, связан
  с client, epoch, exact filters/limit и окном ≤300 секунд от начала GET.
  Смена фильтров/owner/restart сбрасывает курсор; plaintext journal не создаётся.
- GET использует тот же native bearer/refresh, общий transport limit 4,
  aggregate deadline и abortable bounded stream. A→B/stop закрывает flights,
  DTO/cursor getters и runtime lease. Stop ждёт фактического drain.
  UI очищает поля/DTO, снимает только свои routes. Dropdown popups изолированы
  nested Navigator; новая B route не удаляется очисткой старой A route.
- `peopleEnabled` выводится из существующего `ownProfileEnabled`; конфигурация и
  исходные default-off flags не изменены. Публичное media и personal-chat POST
  остаются следующими отдельно проверяемыми возможностями.

## Адресные доказательства

Flutter **3.32.5**, workspace toolchain; no build/cloud/API activation:

- 6 новых client cases PASS: filters/default-off, exact GET + sparse paging,
  nullable detail/byte retention, cursor scope/window/restart, malformed
  HTTP/schema/private/media/budget/order, shared current token refresh/A→B,
  общий четырёхслотовый transport и stream deadline/abort.
- 2 новых widget cases PASS: реальный 360px gate → sparse directory → detail →
  own profile → native chats; реальные country/region/gender/compatibility
  селекторы и 2x text. A→B с pending directory/detail, late A result и новой
  B MaterialRoute: B остаётся открыта, A fields/DTO/route отсутствуют.
- После узкой copy-поправки повторён только существующий 360px sparse-selector
  case: **PASS**. Проверены отсутствие definitive no-results текста и активное
  продолжение на sparse page, а затем сообщение только на terminal empty page.
- 2 изменённых search-entry widget regressions PASS: directory → own edit →
  один save → fresh full-profile; A/B old editor/late profile + 360px keyboard.
  Старый geography fixture имеет `onboarding=test`: его первый own-profile
  экран не меняется, файл теста не правился/не расширялся.
- Scoped analyze 11 файлов: **0 errors, 0 warnings**; 3 прежних curly-braces
  info в неизменённых строках auth client (нынешние 399/1129/1137).
  Catalog presence: 36 labels во всех **23** bundled catalogs, missing=0;
  новых ключей, облачного перевода и catalog rewrites нет. `git diff --check` PASS.
- Fake-clock `pumpAndSettle` во время незавершённого GET может ускорить deadline:
  сценарии ждут реальный request/route через bounded pump/runAsync condition,
  затем settle. Это не ослабляет deadline или A/B guards в продукте.

Локальные fixtures доказывают клиентские границы и UI-сценарии, не live
privacy/visibility, число eligible пользователей или readiness медиа.

## Привязка исходников

Bundle SHA256 (ordered `path\0sha256\n`): `384477c1332f3037bfeaac1c0b27f2b292a7204e30a2df821ab8aa9bf923ad83`.

| Файл | SHA256 |
|---|---|
| `lib/service/timeweb_people.dart` | `988c5458430f8ab0cb1ecc6e6766baab10a091bd591a480f0288c6c6d19677f9` |
| `lib/service/timeweb_auth_client.dart` | `358550fd757c0bbf07af73086bb9e83a7511147f4335f54d7d12db890b243088` |
| `lib/service/timeweb_app_runtime.dart` | `adb693095b9a2c61887f295c0a32d9089162c0a93dece015ac8e4f09b80f961f` |
| `lib/presentation/screens/auth/timeweb_session_gate.dart` | `3fa8292c6954822a56a28d96ed8689435b6a12d7dfe5cd217238b54479a48135` |
| `lib/presentation/screens/profile/timeweb_own_profile_page.dart` | `92e26794c73523baf2253007f8fa35055c5daf51853b532d9e465b3cffe77865` |
| `lib/presentation/screens/list_of_users/timeweb_people_page.dart` | `16b977cbfc47705f2c3d3ad6ad67164629df25e0a49de19f6f543feb97c4bda0` |
| `lib/presentation/screens/list_of_users/show/timeweb_person_page.dart` | `f075f93d98dbda2580f11d5362c3911695b206e84b921802d22ce7e6d11bc162` |
| `test/timeweb_people_client_test.dart` | `c5044d5d6c690c937dda5846f58be953111d0b35cf56696467c38747605f0201` |
| `test/timeweb_people_widget_test.dart` | `9de0b66ea288bc01fa85521b209b51d929f686daf9e9dc5ffed57c3684019d3b` |
| `test/support/timeweb_people_fixtures.dart` | `3781f99291f6701485ffcc3028dd68928cea51ce0a24896b8677f7ca37e8d959` |
| `test/timeweb_current_own_profile_test.dart` | `ea0d000df3cf31f1d03d66ebd953cda21fb192475d6d31a8c50391c31d2cf421` |
