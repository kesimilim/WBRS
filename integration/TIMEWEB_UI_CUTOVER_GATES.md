# Full Flutter Timeweb cutover: scoped source recommendation — 2026-10-01

Это **read-only source inspection** для root. Flutter/backend code не изменялись; build/analyze/tests/live requests не запускались. Дизайн, платежи, ML Kit и исторические ТЗ не пересматривались. Live deployment/import/readiness сюда не выводятся из наличия исходных файлов.

Готовый native API ещё не означает Timeweb APK: `TimewebAuthClient`/`TimewebConversationClient` не используются текущими экранами; `AppBackend.initialize()` всегда запускает Firebase, UI проверяет `firebaseAuth.currentUser` и получает `DocumentSnapshot/QuerySnapshot` из Firestore. Native bearer не создаёт Firebase `User` и не авторизует Firebase SDK. Замена только кнопки входа оставит остальные экраны без ожидаемой identity/read/write authority.

Самый опасный прямой mapping: `/v1/me/profile` сейчас выдаёт только `uid/fullName/country/city/group`, inactive/missing-profile — 404. `SessionGate` и `accountDestination` требуют `status`, `profileDetailsSaved`, `isRegistrationEnd`, legacy `группа`, `age/pol/about/hobbi`; `SessionService.hydrate` дополнительно ожидает `rost/deti/balance`. Если подать текущий DTO как users map, существующий завершённый профиль будет принят за незавершённую регистрацию. Нельзя выводить completion/lifecycle из отсутствующих полей или превращать 404 в «новый пользователь».

## Минимальные точные места подключения

| Seam | Текущий source | Что подключать, сохраняя существующие widgets/layout |
|---|---|---|
| Backend bootstrap | `lib/service/app_backend.dart:44`, `lib/main.dart:59` | Один явный backend mode/public HTTPS endpoint. Native client + Android secure store + restore создаются один раз; до gates production default остаётся Firebase. Firebase messaging/Crashlytics при необходимости отдельны от user-data backend, не должны автоматически открыть Firestore. |
| Auth/session facade | `lib/service/auth_service.dart:17`, login `login_page.dart:219`, register `register_page.dart:162`, reset `login_page.dart:209`, settings `profile_page.dart:564/678` | Provider-neutral current identity/epoch/session notifications + native restore/login/logout/shared refresh/close. Preserve remember_me/error/unknown-outcome behavior; один client/store, confirmed clear перед B. Не подделывать Firebase User и не map unknown в подтверждённый logout/login. |
| Session/profile gate | `session_gate.dart:65/87/94`, `account_destination.dart:7/23`, `session_service.dart:72`, own `profile_page.dart:69` | Явный full own-profile/onboarding/lifecycle DTO → уже существующий destination/hydration model. Provider-neutral ready UID; cancel/reset old account streams/routes/image state. |
| Chat presenter/read repository | `home_page.dart:82/279`, `chat_room_list.dart:29/35`, `chatscreen.dart:76/131/153/308` | Typed bounded pages → existing row/message content; peer supplied by DTO. Cursor вместо Firestore document cursor, account epoch checks. `ChatRoomList` сейчас принимает DocumentSnapshot: изменить data input seam, не создавать подставной QuerySnapshot. |
| Meeting presenter/read repository | `meetings.dart:41/192`, `meet_chat_screen/chat_page.dart:88/151/175/233/900`, individual `about_individual_meet.dart:57/200/280` | Typed details/messages/participants pages вместо DocumentSnapshot/raw users list, historical own_removed только explicit. Existing meeting detail/participants widgets сохраняются; DTO availability/membership/privacy governs actions. |
| Mutation/media boundaries | `ChatSubmissionService`, `MeetingWriteService`, `MeetingMembershipService`, `ProfileRegistrationService`, `DatabaseService`, `SocialService`, `ProfileDeleteService`, profile upload, AdminAccess/private directory, main push/presence | Отдельные authenticated API repositories с request identity/operation-ID/idempotency/reconcile и permission checks. Здесь один login adapter не заменяет прямые Firestore transactions/storage uploads. |

## 10 конкретных gating contracts для полного приложения

| # | Контракт | Уже есть в подготовленном source / что ещё необходимо |
|---|---|---|
| 1 | Current session/identity, restore/login/refresh/logout/current/all, errors/remember_me, A→B | Native standalone client, secure store и API baseline есть; необходимо подключить facade и authState consumers (`main`, `SessionGate`, `AdminGuard`, current UID checks) без mixed authority. App/engine/lifecycle proof нового APK остаётся. |
| 2 | Регистрация, reset/change password, email verification, reauth/delete account | Текущий UI вызывает Firebase createUser/sendPasswordReset/updatePassword/reauth/delete. Native routes/client этих действий нет. Нужны bounded server contracts, mailbox flow и token invalidation, а не скрытая регистрация новых пользователей в прежнем Firebase. |
| 3 | Полный own profile + onboarding/test completion + profile edit/privacy/lifecycle | Current own whitelist шесть полей; не покрывает destination/hydration/settings. Нужны явные partial/completed/test/active/deleted/disabled states и сохраняемые UI поля, profile/update/test/delete actions с truthful legacy mapping. Email — private self field, не из public directory. |
| 4 | Public user search/detail/compatibility + visitors/friends + start personal chat | `ProfilesList`, SomebodyProfile и SocialService читают users/visiters/friends и создают room в Firestore. Native own profile/own-chat discovery этого не заменяют. Нужны pagination/filter/visibility/active counterpart checks и controlled room creation; исчезнувший/disabled user не interactive. |
| 5 | Personal chat history **и действующий чат** | Native read pages готовы для immutable reviewed snapshot; текущий экран — live snapshots. Нужны new-message/delta delivery, create/send text/quote/share with durable operation-ID/reconcile, delete where supported, read receipts/unread, mute settings. Готовый GET возвращает `readReceiptsWritten:false`: открытие экрана не должно выдумывать read-write success. Favorites/archive сейчас local per-UID; можно сохранить их семантику с новой identity. |
| 6 | Meeting browse/details/participants + create/edit/join/leave/kick/chat | Existing main list читает **все** meets и фильтрует geography; `/v1/meetings` готов только для own meetings. Нужен browse/filter contract, mutations/live membership authority, creator permissions, removed archive и messages. Snapshot membership не authority для новых join/kick или приватности после source cutover. |
| 7 | Feed/wall/posts/comments/likes/reports/author grants | Existing SocialService полностью Firestore/Storage transactions/streams. Conversation shared-content DTO не является feed/wall API. Нужны same-ID content/read pages, idempotent likes/comment/post/report actions, delete/block/manual moderation и source delta. Никакая отдельная версия Ксюши этой проверкой не подменяется. |
| 8 | Admin role/private directory/list/mutations/audit | AdminAccess сейчас Firebase custom claim; AdminPrivateDirectory — separate private_users Firestore. Native session не приносит эту claim в UI. Нужны server-authoritative role/revocation + private-email directory + user/meeting/content moderation/actions with audit, без client UID lists или роли из обычного profile map. |
| 9 | Private media ownership/promotion/HTTP lease/read/upload/gallery/event images | Server media lease core/S3 GET-only adapter подготовлены другим агентом, **HTTP route/UI/promotion/own gallery нет**. Existing DTO `mediaReady:false`/quarantined не public URL. Нужны verified ownership→HTTP bounded lease→client image data, upload/thumbnail/gallery/selected avatar/update/delete paths и truthful meeting image assignment. Не использовать Firebase download token как публичный S3 URL. |
| 10 | Notifications/presence/device/session integration + controlled final cutover | main пишет TOKENS/presence, SocialService читает notices; unread taps/read/preferences тоже Firestore. Нужны device register/detach, delivery/read/preferences/destination checks and live updates with epoch isolation. Затем final source delta/defined authority/rollback и exact new APK controlled login old credentials→own profile→chat+meeting read/write→logout A/B→restart, с HTTPS server и privacy proofs. Наличие local tests/Keystore proof не закрывает эту end-to-end границу. |

Отдельная обязательная совместимость защищённого существующего функционала: shop/gift/payment flows используют `firebaseAuth.currentUser`, user balance и Firestore. В этой задаче не менялась их логика и не предлагается менять платежный расчёт/Robokassa. Перед global Auth switch root должен сохранить их identity/backend contract в отдельной согласованной интеграции. Native-only вход с оставленными прямыми Firebase reads/writes нельзя объявлять полным рабочим cutover.

## Рекомендация root

Сначала зафиксировать full own-profile/onboarding DTO и provider-neutral session identity; затем по ограниченным seams переключать data repositories, сохраняя layout/widgets/ML Kit и защищённые платежные handlers. Не менять production backend define на native, пока хотя бы одна обязательная экранная операция остаётся прямой Firebase user-data операцией без согласованной совместимости. API read snapshot оставить честно historical/read-only до live mutation/delta authority. Завершение — конкретный новый APK, controlled end-to-end proof и серверная авторизация всех обязательных операций, а не создание Firebase User из native UID или включение готового GET в одном экране.

## Привязка к исходникам inspection

- `lib/service/app_backend.dart` SHA-256 `5d6132165cb44be7240044e71888586146a3ba08cb807ac5e88e9d486e271919`
- `lib/service/auth_service.dart` SHA-256 `ffcba1e07eb8aff16f54abcd2e6fb780e7ddba3febcf85bd63eec78056c8ea92`
- `lib/presentation/screens/auth/session_gate.dart` SHA-256 `5870f5d6cf394bc6aac48bd7bd29d7e565564d163a182dad9f921f01c0df31ab`
- `lib/core/utils/account_destination.dart` SHA-256 `d6a1c1f14a8dc3724a5179acdccd99ef6e816c576480290a5bbd214bdef183ab`
- `lib/service/session_service.dart` SHA-256 `d802be18e2268a9668e4a16ba1287941994e056b4ec2815312fcd9bd12462296`
- `lib/presentation/screens/auth/login_screen/login_page.dart` SHA-256 `e0992106b7343717253ab426563b7e0811f7ab4a0e91c7071c034b0e5e60700a`
- `lib/presentation/screens/auth/register_screen/register_page.dart` SHA-256 `8890531cf86bbe4c806279c960d1a868df56e832354dff1d4e1cbda20f3aa25d`
- `lib/presentation/screens/home/home_page.dart` SHA-256 `78bb2f538583bb31ce04ea36658ee6c228608bf16ccc808607e8698a8ce0dd1b`
- `lib/app/widgets/chat_room_list.dart` SHA-256 `db9f5e5c0e8a413008d77ff6f9e282a8175857b8a4c8e2fc1b6ab2d3d9f8aa2a`
- `lib/presentation/screens/chat_screen/chatscreen.dart` SHA-256 `049aa50332aae13ba6d22a6819f5d8792b9ade04062d63c2df9b5d269ca7ca14`
- `lib/presentation/screens/meet_chat_screen/chat_page.dart` SHA-256 `93209ac924fca1a455ab38bee285beb8be953f0e4144cb0b19781b325af4f4b7`
- `lib/presentation/screens/list_of_meets/meetings.dart` SHA-256 `1f208f118b36c918d0588a3b4287f1e81e96a0cdd2be8a85b90a5b112d3cb59a`
- `lib/presentation/screens/profile/profile_page.dart` SHA-256 `36953050ff9a7a11413f0b09de227ba0dea781c49307904fba0da5921fcf6c34`
- `lib/service/admin_access.dart` SHA-256 `cf2b2846b3612190b4268df2a6ac9bf00f03ea99ee085ed31c302e4c2bda5f29`
- `server/timeweb/python-stand/profile_store.py` SHA-256 `3aaee0cf92207f1c93ff27027bb7dd6d178c87b175dbfdc3d34831dba0d10819`
- `server/timeweb/python-stand/app.py` SHA-256 `eb8934fe330b182947765277f985063e9ee7f6ec177c359d46fe2f5e7bb4035f`
- `lib/service/timeweb_auth_client.dart` SHA-256 `03afbcefb4f3e0aad31c3c0856e8348783f7b2998e22e0fd8263e78215c67906`
- `lib/service/timeweb_conversation_client.dart` SHA-256 `654097524eb2af92478a2de85ed6f48a6254536c7b7953f84e99a766bbfa1d21`
