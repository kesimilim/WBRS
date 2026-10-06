# Native admin: Flutter read client и список пользователей

Локально подготовлен клиент `GET /v1/runtime/admin/users` для backend contract `7c25f8c`. Экран доступен через текущий native собственный профиль только после одного ограниченного server-role probe `limit=1` на epoch общего `TimewebAppRuntime`. Данные probe не показываются и не сохраняются. Ошибка или 403 скрывает пункт; повторное открытие собственного профиля в том же epoch не запускает новый probe. Каждый настоящий запрос страницы заново проверяется сервером: UI affordance не является ролью, token claim или разрешением на другие действия.

Реализация использует прежние `currentOwnProfileEnabled`, `currentReadsEnabled` и `runtimeWritesEnabled`; новые flags, Firebase-identity, списки email администраторов, создание/назначение ролей и действия над аккаунтами отсутствуют. Server gates остаются существующими WRITES + `canonical-current-v1`; этот клиент их не включает.

## Минимальный API

```dart
TimewebAdminUsersRequest(query: '', limit: 30);
client.readAdminUsers(request, cursor: previous.nextCursor);
runtime.readAdminUsers(request, cursor: previous.nextCursor);
runtime.probeAdminUsersAccess(); // Future<bool>, один GET limit=1 за epoch
TimewebAdminUsersPage(runtime: runtime, onAccessDenied: optionalCallback);
```

Response model `TimewebAdminUsersResult` содержит guarded `items` и `nextCursor`. `TimewebAdminUser` содержит только UID, nullable email/fullName/age, exact active/blocked/deleted lifecycle и bool disabled. Account actor может присутствовать в списке. Null и пустые строки сохраняются отдельно; число не преобразуется из строки/bool/double. Неизвестный lifecycle, лишнее поле, UID duplicate/order mismatch, недопустимые строки или типы закрывают весь ответ. DTO, request и cursor имеют redacted `toString`; private values не пишутся в preferences/journal/logs и не передаются в public profile.

Транспорт использует один auth owner, текущий bearer, общий лимит четырёх HTTP transfers, исходный abortable request, тот же request deadline и drain при смене epoch/stop. Отдельного network budget нет. Ответ ограничен 64 KiB, JSON, `no-store`, без public cache/redirects/compression. Ошибочные bodies не декодируются в UI. Native 401 использует прежний refresh-once/invalidate contract; `TimewebAdminAccessDenied` на 403 оставляет обычную native session действующей. При замеченном 403 экран очищает текущую страницу, запрос и cursor, а собственный профиль скрывает entry. Это не мгновенный отзыв уже доставленного HTTP body: сервер заново проверяет роль при каждом чтении.

Cursor — opaque RAM capability, без публичного конструктора/decoder/serialization. Он связан с auth owner, session epoch/UID, exact submitted trimmed query и limit; срок клиента консервативно 300 секунд от начала исходного запроса. Новый owner/restart не принимает старый cursor. Client binding намеренно может отказать в переиспользовании cursor при изменении регистра prefix, хотя сервер casefold-нормализует свой scope.

## Поиск и ограничение памяти

UI показывает одну страницу до 30 пользователей. Непустой prefix отправляется по явному нажатию «Поиск»/Enter; изменение текста сразу очищает предыдущую страницу/cursor и не запускает запрос. «Обновить» начинает текущий поиск заново. «Загрузить ещё» заменяет страницу следующей и никогда не запускает автоматический поиск/scan. Пустая страница с nextCursor законна и оставляет кнопку продолжения; только пустая terminal page показывает отсутствие результатов. Retry повторяет тот же read request/cursor, без mutation или обхода expiry.

Пустой prefix означает список без фильтра; UI показывает существующие метки «Имя / Email». Клиент проверяет максимум 100 исходных Unicode code points/400 UTF-8 bytes, malformed UTF-16 и controls; для непустого текста UI/DTO требуют минимум 2 исходных code points. Python backend остаётся единственным авторитетом `strip().casefold()` и дополнительно проверяет длину после casefold. Dart lowercase не подменяет casefold; output строки не нормализуются. У этого клиента есть консервативное ограничение: односимвольный prefix, который casefold расширяет до двух символов, не отправляется. Casefold expansion сверх server limit даёт безопасную generic ошибку, без выдачи предыдущих результатов.

Во время загрузки controls заблокированы. На A→B guarded DTO/cursor старого actor перестают читаться, page/query/private values очищаются, late A result не становится entry или страницей B. Cleanup удаляет только исходный route и не закрывает более новую B destination. Остальные профильные, chat, payment и media contracts не изменены.

Использованы существующие localization keys и общие CLRS background/frame/theme; новые каталоги или изображения не добавлены. Поля карточки ограничены видимыми строками с ellipsis, без неверного усечения исходного DTO. UI не содержит admin write buttons, realtime listeners, totals, произвольного contains/regex поиска или скачивания полного списка.

## Проверка и граница доказательства

Focused synthetic client tests проверяют gates/input bounds, exact GET/nullable types, sparse paging, RAM cursor binding/expiry, typed 403 без logout, refresh/repeated 401, strict response/privacy/body bounds, общий transfer cap + abort/drain и late A/retained DTO refusal. Actual widget tests при ширине 360 px проверяют admin probe/entry → sparse → next → prefix → revoke, удвоенный текст без overflow, nonadmin и probe-once после remount, active page A→B и поздний успешный probe A при nonadmin B. Fixtures используют только синтетические UID/email `.invalid`; Firebase не инициализируется.

Адресные команды:

```sh
../toolchains/flutter-3.32.5/bin/flutter test --no-pub test/timeweb_admin_users_client_test.dart test/timeweb_admin_users_widget_test.dart
../toolchains/flutter-3.32.5/bin/flutter analyze --no-pub lib/service/timeweb_admin_users.dart lib/service/timeweb_auth_client.dart lib/service/timeweb_app_runtime.dart lib/presentation/screens/admin/timeweb_admin_users_page.dart lib/presentation/screens/profile/timeweb_own_profile_page.dart test/timeweb_admin_users_client_test.dart test/timeweb_admin_users_widget_test.dart
```

Финальный адресный прогон: **12 cases PASS** (8 client + 4 actual widget), **0 errors / 0 warnings** при scoped analyze; остаются 3 прежних `curly_braces_in_flow_control_structures` info в неизменённых строках authclient. Новые module/UI/tests не добавляют analyzer notices. Проверка использованных keys в 23 существующих catalogs: missing=0; каталоги не изменялись. `git diff --check` PASS.

Эти проверки доказывают локальный client/UI contract на synthetic HTTP. Реальные server-role grants, deployed GET, production privacy/latency, APK/device и flags activation этим этапом не проверялись. Облачных вызовов, SQL/role mutations, build/deploy и broad suite нет.
