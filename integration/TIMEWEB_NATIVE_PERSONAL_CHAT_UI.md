# Native личный чат: клиент и переход из публичной анкеты

Добавлена настоящая `chat.open-personal.v1` из текущей публичной анкеты через тот же `TimewebAppRuntime`/native session. Контракт сервера зафиксирован в `TIMEWEB_NATIVE_PERSONAL_CHAT.md`; people wire DTO, `avatar:null`, `mediaReady:false`, старые send/read requests и форматы их журналов сохраняются.

## Поведение приложения

Кнопка «Отправить сообщение» доступна при существующих own-profile/current-read/runtime-write/native-chat gates. Никаких новых flags или их включения нет. Операция принимает только exact target UID; native actor берётся из bearer session. HTTP 201 для созданного и 200 для найденного чата проверяются вместе с exact result `{chatId,peerUid,created,chatRevision}` и `entityRevision==chatRevision`. Импортированный chatId сохраняется; пустой/чужой UID, extra fields, некорректная revision или противоречивый status/result не открывают экран.

Перед POST узкий application-private журнал сохраняет original actor/origin/target UID, lowercase UUIDv4 и canonical request hash. Файл ≤8192 bytes; имя SHA256(origin + NUL + actor UID + NUL + target UID). Эти UID — routing metadata, не credentials. В журнале нет token/password, people cursors, profile/media/source maps. Подготовка сериализована, flush + rename выполняются до POST. Duplicate taps возвращают один original Future. Закрытие страницы или смена A→B до durable acknowledgement сохраняет original intent; поздний A не удаляет его и не меняет B.

При неизвестном исходе и после перезапуска показывается «Проверить результат». Он делает свежий GET lookup original UUID/hash; `not_found`, 503 или не подтверждённый lookup сохраняют intent и никогда не разрешают новый POST автоматически. После подтверждённого journal ACK original bound reference остаётся в RAM текущего owner/epoch. Каждый повторный tap после возврата из чата делает fresh lookup того же operationId/hash. Успешный cached receipt не заменяет свежий visibility/membership guard; прежние операции сохраняют своё retention правило. Перед lookup usable cache сбрасывается. Fresh 503/отказ никогда не открывает предыдущий экран. Original committed 404/409 failure receipts по-прежнему ACK действительный отказ и показывают безопасные сообщения. Отдельный personal lookup-only HTTP404 exact `{error:person_unavailable}` означает текущий visibility denial: unknown + typed failure, canAcknowledge=false. Он сохраняет original pending journal либо check-only RAM reference после ранее завершённого ACK; убирает cached публичную анкету и показывает «Профиль недоступен». Здоровый actor остаётся в сессии, visibility denial не запускает auth refresh/logout. 409 original failure даёт «Чат недоступен». Серверные ключи пользователю не показываются. Новая action после definite rejection возможна только после явного обновления анкеты и нового tap.

Только подтверждённый owner-bound receipt открывает существующий `TimewebChatPage`: сначала fresh GET сообщений exact chatId, проверка owner/client/epoch и revision ≥ receipt. Поля `CurrentChat` и его настройки не выдумываются. Пока receipt не даёт имени, экран использует прежний общий заголовок. Начальный zero knownRead — локальная нижняя граница до current own-read receipt, не объявление серверного счётчика. Существующие send/read journals восстанавливаются для настоящего chatId; composer, send/read, events и текущий дизайн используют рабочий native chat flow. Firebase identity, globals/hydration и Firebase routes отсутствуют.

Активные mutation transfers сохраняют прежний общий лимит 4 и deadline/64 KiB response bound. A→B немедленно aborts их HTTP transport; runtime stop ждёт фактический drain транспорта и журналов. Abort не отменяет серверный COMMIT и не удаляет original journal. DTO/поля закрытой страницы недоступны, текущая публичная route удаляется только сама, без pop новых B routes. Existing AppSession bounded wait возвращает pending+settled после waitTimeout; runtime.stop затем сохраняет прежний контракт ожидания фактического drain. Если custom transport игнорирует abort и не завершает работу, этот final drain future остаётся pending: deadline ответа не выдаётся за реальное завершение I/O, replacement owner не запускается по ложному подтверждению. Дополнительный stop refactor в review correction не выполнялся.

## Адресное подтверждение

Flutter 3.32.5 из workspace. 6 отдельных client/flow scenarios PASS адресными запусками:

- exact body/hash/native bearer, 201 create, 200 imported ID, duplicate Future, default-off/invalid target;
- malformed peer/ID/revision/status/extra field, response >65536, exact safe 404/409 receipts;
- durable before POST + double tap + lost ACK + restart + `not_found` lookup-only + committed imported receipt → fresh real messages GET;
- A→B abort + late A refused by `staleSession`, A journal retained, no new B POST;
- stop aborts and waits actual held transfer drain, original intent remains;
- closed page + late confirmed ACK + fresh lookup503 remains unknown; subsequent thin404 person-unavailable lookup refusal retains pending journal, has no usable receipt and never opens cached chat.

3 new actual widget scenarios подтверждены адресно: 360px native Gate→directory→public profile→imported `TimewebChatPage`→canonical send, including 2x text/keyboard; unknown POST→restart→check original fresh lookup→real chat with exactly one POST. Добавленный review scenario PASS: first open→return→green repeat original lookup→return→503 (no navigation)→green→return→hidden thin404 (cached fields removed, no auth calls, check remains available), с одним personal POST и прежним импортированным ID. One affected existing 360px sparse-directory/filter/profile/chats widget scenario also PASS; its former no-chat-action assertion is replaced by the real button assertion before the lazy ListView scrolls it out of the tree. All are synthetic fixtures; no provider/API/cloud/live DB calls.

Initial scoped analyze on the 10 listed files: **0 errors, 0 warnings**, 15 existing curly-braces info (3 authclient + 12 shared mutations). All 15 offending statements are present in HEAD. Final review correction scoped analyze on its 5 modified Dart source/test files: **0 errors, 0 warnings**, only the same 12 shared-mutations infos; no new info remains. Final correction reran only the new repeat-open widget scenario and affected close/lateACK/lookup503→thin404 journal case; no broad repeat. Existing localized labels checked in **23 catalogs × 5 keys, missing=0**, no catalogs rewritten. `git diff --check` PASS. No broad suite, build/APK, commit/push, DB/schema changes, deployment or flags activation performed by this stage. APK44 remains unchanged and does not contain this later source.

## Exact source binding

SHA256 is over exact bytes. Bundle SHA256 of UTF-8 manifest lines `hash + two spaces + repository-relative path + newline`, sorted by path: **cb0d13d5f08cb650dc3167dcb1eb71632d3ec7435a7a2942a2d6f0d5289775f8**. This document is excluded from its own manifest.

| File | SHA256 |
|---|---|
| `lib/presentation/screens/list_of_users/show/timeweb_person_page.dart` | `a3e1cfec2e6538b1a6e38376efb85f4c3e11b917b23bd25c97ee273773170d9f` |
| `lib/service/timeweb_app_runtime.dart` | `8d50263dba2af30938f30a5e66f6c3b25a5b36d0a58af3e2a8a1d44b04237138` |
| `lib/service/timeweb_auth_client.dart` | `9fed0b7b095f17a81fa9bfdb8817a854d815c8e9f06d802bc7ee229a07c1c4a7` |
| `lib/service/timeweb_chat_flow.dart` | `b47a35ccc4110f0676fa743b24df5b71e9734b46a0e92b222cd34b20568cbded` |
| `lib/service/timeweb_mutations.dart` | `18c7bff7e7a121b761a6b25749d229b9bc042765554133a3e99e1cde8dafc403` |
| `lib/service/timeweb_personal_chat.dart` | `18c06f3847738f01bc6224929baa547e70866863ef9d2a5e04a98c725795ece5` |
| `lib/service/timeweb_personal_chat_flow.dart` | `4bdd5de0d5bbf3da6ea4ac96a6e5f15a618771c25b7398b590d7ba0e37aeb825` |
| `test/timeweb_people_widget_test.dart` | `23ba57968950049a155e28638c2329a5da86c4950be87ef8832c94f93f100c34` |
| `test/timeweb_personal_chat_test.dart` | `4319441381c787ef94c4c031248254e2a754aee9447059849216233d04acb98d` |
| `test/timeweb_personal_chat_widget_test.dart` | `d4a357fbb04adc31644259a69e9f97d5d52dfdaffc28f51a1c7be3987064ce3f` |

Следующая граница — root review/commit/publish и отдельно разрешённое live A/B proof с текущими gates/grants/visibility. Эти локальные fixtures не подтверждают live создание пары, доступ после hide/disable, SQL permissions или окончание миграции. Public media и остальные функции остаются отдельными этапами.
