# Native Auth для существующего Python 3.12 stand

Подготовлены `native_credentials.py`, `native_sessions.py`, `native_auth.py` и их тесты. В `app.py` подключены HTTP routes login/refresh/logout и native bearer для собственного профиля. Они выключены по умолчанию, не изменяют Firebase, не создают аккаунты, не выполняют DDL и не подключаются к сети при импорте. 1 октября 2026 создана отдельная runtime role и подтверждены её реальное TLS-соединение, три согласованных права только на staging и отказ в доступе к `default_db`. Серверный TLS-коммит `bc5fe138` опубликован в GitLab; живой вход прежним паролем и переключение APK ещё не подтверждены.

`NativeAuthService.from_env()` возвращает `None`, пока **оба** `CLRS_NATIVE_AUTH_ENABLED` и `CLRS_NATIVE_AUTH_WRITES_ENABLED` не равны `1`. Текущему `clrs_api_ro` не выдаются write permissions. Наличие подготовленных файлов/прохождение тестов не означает включение native auth или готовность `/readyz`.

## Перед включением

1. Получить завершённый segmented full archive и FINAL manifest. Импортировать raw данные, нормализованные аккаунты/профили/идентичности и encrypted credentials; выполнить независимые readback/receipt проверки. См. `../CREDENTIAL_STAGE.md`.
2. Сохранить hashConfig из проверенного encrypted credential bundle и wrapping key только в server secrets. Значения должны полностью совпадать с credential stage: raw base64 signerKey/saltSeparator, rounds/memoryCost, configRef, wrapping key. Google Owner ADC/Firebase export credentials серверу не нужны.
3. Использовать отдельную runtime role. Строгий режим разрешает прямые `SELECT` только на `clrs_staging.accounts` и `clrs_staging.auth_credentials`, а также `SELECT, INSERT, UPDATE` только на `clrs_staging.device_sessions`. Для ограниченного интерфейса Timeweb явно согласован и реализован альтернативный `CLRS_NATIVE_AUTH_PERMISSION_MODEL=provider-database-v1`: ровно `SELECT, INSERT, UPDATE` на `clrs_staging.*`. Он шире табличного режима, но не даёт DELETE/DDL/GRANT OPTION или доступ к другим БД. Смешанные/дополнительные права отвергаются. Именно второй режим создан и проверен для `clrs_native_auth`; миграционный пользователь не используется для HTTP.
4. Выполнить контролируемые HTTP login/refresh/logout/current-status тесты на stand после включения подготовленных routes. Проверить реальный источник IP от прокси Timeweb: текущий `REMOTE_ADDR` безопасен от spoofed X-Forwarded-For, но один общий адрес прокси может сделать per-peer limit общим для всех пользователей. Не доверять заголовку до проверки контролируемой proxy-интеграции. Только после этого переключать APK. Регистрация новых пользователей, password reset/change, social providers и email verification — следующие отдельные этапы.

## Server env/secrets

Не коммитить и не передавать в APK значения:

- `CLRS_NATIVE_AUTH_DB_URL`: URL отдельной технической роли, только `mysql://…/clrs_staging?sslmode=verify-full` с DNS-именем БД. IP/local host запрещены.
- `CLRS_NATIVE_AUTH_DB_CA_FILE`: необязательный абсолютный путь к серверному CA. При отсутствии native и общего `CLRS_DB_CA_FILE` используется `timeweb-ca.pem` из серверной сборки. Явный пустой/неверный путь не заменяется предположением и блокирует соединение.
- `CLRS_NATIVE_SCRYPT_CONFIG_JSON`: точный JSON hashConfig из sealed credential bundle, не более 4 KiB, включая secret signerKey.
- `CLRS_NATIVE_CREDENTIAL_CONFIG_REF`: тот же стабильный configRef, который использовал credential stage.
- `CLRS_NATIVE_CREDENTIAL_WRAPPING_KEY_B64`: тот же 32-байтовый wrapping key, base64/base64url.
- `CLRS_NATIVE_SESSION_KEY_B64`: отдельный случайный 32-байтовый server secret для session/rate HMAC. Он не должен совпадать с wrapping key.
- `CLRS_NATIVE_AUTH_ENABLED=1` и `CLRS_NATIVE_AUTH_WRITES_ENABLED=1`: включать только после предыдущих проверок.

TLS использует `ssl.create_default_context`, `CERT_REQUIRED`, `check_hostname=True`; проверка сертификата не отключается. На каждом соединении проверяются прямые table grants, MySQL 8.4/staging target, непустой TLS cipher; SQL использует placeholders и strict session mode. Конфигурация для native role отдельная от read-only API role. Existing Python 3.12/cryptography/PyMySQL dependencies достаточны; пакеты не добавлялись.

## Совместимость паролей

AES-GCM совместим с Node `auth-credential-storage.mjs`: blob — nonce12/tag16/ciphertext; AAD — фиксированный JSON-массив с UID/таблицей/configRef/configIdentity/version/providers/status/email verification/validSince. Python использует UTF-8, `ensure_ascii=False`, compact separators; порядок ключей MySQL JSON не влияет на AAD. Тип `password_version` (`0` или `"0"`) и исходные base64 строки сохраняются.

Firebase modified SCRYPT: N=`2^memoryCost`, r=`rounds`, p=1, salt=`user salt + saltSeparator`, derived length64; AES-256-CTR с нулевым IV шифрует signerKey первыми32 derived bytes; hash сравнивается через constant-time compare. Это реализовано по [официальному Firebase SCRYPT алгоритму и публичному примеру](https://github.com/firebase/scrypt). Другой algorithm/version/redacted/hash-length/memory bound отвергается; исходные пароли не нормализуются и не обрезаются.

Максимум два KDF worker на процесс, по 64 MiB memory limit. Нет неограниченной очереди: третья одновременная работа получает generic unavailable. KDF ждут не более1.5с; по таймауту его слот занят до **реального** окончания worker, а не освобождается для бесконечного накопления фоновой работы. Python не гарантирует обнуление всех immutable password/derived bytes в памяти; они не пишутся в файлы/SQL/логи.

Аккаунт и encrypted credential прочитаны до KDF, затем вновь прочитаны и заблокированы **в той же транзакции, где создаётся сессия**. UID/tokenVersion/ciphertext snapshot должен оставаться прежним; blocked/deleted/disabled и `credential.disabled` отвергаются. Блокировка или смена credential во время KDF не приводит к выпуску сессии.

## Сессии без изменения схемы

Используется существующая `device_sessions`. Access token: `na1.<random session ID>.<server HMAC>`. Refresh token: `nr1.<random session ID>.<32 random bytes>`. Клиент хранит opaque tokens в защищённом хранилище, отправляет их только через HTTPS, никогда в query string. Raw токенов в БД нет.

`refresh_token_hash` хранит версионированный 52-byte envelope:

| Байты | Значение |
|---|---|
| 0–3 | `NS1\0` marker |
| 4–11 | uint64 tokenVersion в big endian |
| 12–19 | uint64 expiry access token в Unix seconds |
| 20–51 | HMAC-SHA256 refresh secret и immutable session binding |

Это помещается в существующий VARBINARY(255); DDL/ALTER не требуется. HMAC имеет разные домены для access и refresh. Access MAC связывает весь envelope, включая refresh HMAC, UID/device/session ID, issued/expiry/rotated_from. Refresh MAC связывает immutable identity/time и первые20 bytes envelope. Подмена UID/device/time/hash invalidates proof.

Access expiry —15мин, refresh expiry —14дней. На каждом accepted access/refresh/logout чтение текущего `accounts` проверяет `disabled`, lifecycle и tokenVersion; изменение блокировки/версии сразу отвергает прежнюю сессию. `authorize()` возвращает только подтверждённую NativeIdentity; target UID из HTTP/JSON не принимается. При выдаче новой сессии её SQL запись читается обратно и сверяется до COMMIT.

Refresh блокирует старую session/account строку, помечает старую session revoked, создаёт новую с `rotated_from` и коммитит всё одной транзакцией. Повторный **валидный** old refresh — replay: в транзакции отзываются все активные сессии того же UID/device, COMMIT выполняется до generic401. Неправильный refresh secret не вызывает отзыв. Две параллельные попытки refresh сериализуются; вторая рассматривается как authenticated replay. Поэтому клиент должен иметь один shared refresh Future и **не повторять автоматически** refresh после неизвестного сетевого исхода; при таком исходе требуется новый login.

Logout отзывает текущую сессию; `all_sessions=True` отзывает все активные сессии того UID. Он не меняет другие аккаунты/пароли/claims/tokenVersion. Expired/revoked sessions не принимаются. Session rows сохраняются; cleanup старых записей и политика retention — отдельная операция, DELETE у runtime role отсутствует.

## HTTP integration contract

Подключённые routes (доступны только при включении обоих native flags):

- `POST /v1/auth/login`: UTF-8 JSON не более8192 байт; `parse_login_body(raw)` требует ровно email/password/deviceId без duplicate/unknown keys. `service.login(body, peer=trusted_peer)`.
- `POST /v1/auth/refresh`: строгое тело с refreshToken; `service.refresh(token, peer=trusted_peer)`.
- Protected route: строго один Bearer access token `na1.…`; `identity = service.authorize(token, peer=trusted_peer)`, далее доступ только к `identity.uid`. Native token не передавать Firebase verifier и не использовать ошибку native proof как повод для fallback.
- `POST /v1/auth/logout`: access token и обязательный boolean allSessions; `service.logout(token, peer=trusted_peer, all_sessions=value)`.

Content-Length проверяется до чтения; chunked/unknown length, неверный Content-Type, duplicate/unknown JSON keys, токены/target UID в query и multiline bearer отвергаются. Ошибка native proof не вызывает fallback к Google. `/readyz` продолжает отвечать `migration_incomplete`, независимо от наличия подготовленного native кода.

`http_runtime.py` ограничивает stand восемью worker threads и двумя KDF workers. Есть абсолютный 10-секундный срок сокета, включая медленную передачу request line/headers/body, и 10-секундный inactivity timeout. Он прекращает соединение, не повторяет начатую SQL запись; неизвестный результат остаётся неизвестным. Перегрузка получает generic503; медленный запрос не блокирует все остальные последовательно. WSGI request logs и исключения отключены, поэтому traceback не раскрывает секреты. Это один stand/process; distributed limiter и нагрузочный production proof ещё отсутствуют.

`trusted_peer` берётся из контролируемого server socket/proxy integration; пользовательский JSON/X-Forwarded-For здесь не является источником доверия. HTTP adapter должен ограничивать Content-Length/body до чтения, не выводить authorization/body/exception details, возвращать `Cache-Control: no-store`. `NativeRejected` → generic401, `NativeRateLimited` →429/Retry-After60, `NativeUnavailable` →generic503. DB exception details не возвращать и не логировать.

Rate limiter: login peer10/мин и normalized email5/мин; session peer120/мин; HMAC identity keys, максимум4096 записей, очищаются по expiry. Он **per-process**, сбрасывается при рестарте. Несколько workers/instances увеличивают совокупный лимит: перед масштабированием требуется shared limiter/edge policy. Это ограничение не скрывается как production-global защита.

Request budget8с проверяется между этапами/SQL операциями; connect/read/write timeout2с. Уже начатая операция может занимать свой timeout после истечения budget, затем новые операции не запускаются. При ошибке/потере ответа COMMIT raw tokens не возвращаются, INSERT/refresh не повторяются автоматически; активная orphan session может сохраниться до expiry/logout-all. Наличие такой строки не даёт клиенту токен, которого он не получил.

## Проверки и текущая граница

```bash
CLRS_TEST_NODE_BIN='/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/toolchains/node-v22.23.2-darwin-arm64/bin/node' \
  '/Users/anaakovleva/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3' \
  -m unittest -v test_native_auth
```

22/22 native core offline tests прошли Python3.12.14/cryptography50.0.1. Есть официальный password vector, Node→Python и Python→Node AES-GCM fixtures с `0`/`"0"` и non-ASCII UID, GCM tampering/config/version failures, password whitespace, private grants/TLS, current disabled/lifecycle/tokenVersion, block/reset во время KDF, readback, expiry, rotation/replay и parallel model, logout/current/all, lost COMMIT без retry, bounded input/rate/KDF timeout/default-off. HTTP/параллельность —11/11 новых проверок: закрытые default flags, ограниченные тела, generic errors, подтвердившийся UID, здоровье сервиса во время медленного запроса, bounded503, absolute drip deadline, освобождение сокета/слота при отказе запуска watchdog и отсутствие traceback. Прежние 25/25 stand/token/profile тестов прошли после HTTP интеграции.

SQL проверки используют transaction-aware fake, а не реальный MySQL. Тесты не подтверждают live runtime role, деплой, реальные native credentials или вход существующего пользователя. На этом шаге **DB/Firebase userdata writes=0**, native routes не включены. Password reset/change, signup/provider flows, admin claims sync, client session persistence/refresh isolation, source delta/cutover и controlled old-password login остаются обязательными дальнейшими шагами полного Auth переезда.
