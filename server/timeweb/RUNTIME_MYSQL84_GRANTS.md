# Ограниченные пользователи двух runtime сервисов

Подготовлены template/validators/tests; реальные пользователи, GRANT/ALTER USER, browser actions и deploy этим шагом не выполнялись. Только существующая MySQL8.4 `clrs_staging`; новых БД/услуг нет. Migration account с CREATE/REFERENCES не используется публичными runtime сервисами. Строгая модель прав на таблицы остаётся default; отдельно подготовлена явно выбираемая модель прав на одну БД для управляемых пользователей Timeweb.

## Строгая модель по умолчанию

| Технический пользователь | Таблица | Точные права |
|---|---|---|
| `clrs_native_auth` | `clrs_staging.accounts` | SELECT |
| `clrs_native_auth` | `clrs_staging.auth_credentials` | SELECT |
| `clrs_native_auth` | `clrs_staging.device_sessions` | SELECT, INSERT, UPDATE |
| `clrs_legacy_read` | `clrs_staging.accounts` | SELECT |
| `clrs_legacy_read` | `clrs_staging.legacy_source` | SELECT |
| `clrs_legacy_read` | `clrs_staging.legacy_documents` | SELECT |

`USAGE ON *.*` не даёт доступа к таблицам и является ожидаемой строкой SHOW GRANTS; иных global/database grants, roles, GRANT OPTION, DELETE/DDL и доступа к `default_db` в строгой модели быть не должно. Обязательное защищённое соединение проверяется отдельно, как описано ниже.

## Явно выбранная модель для управляемого пользователя Timeweb

Timeweb документирует выбор прав для конкретной базы через панель; выдача прав на отдельные таблицы через эту панель не описана: [пользователи и привилегии](https://timeweb.cloud/docs/dbaas/mysql/users-and-privileges). Поэтому доступен отдельный проверяемый вариант, без автоматического расширения строгой модели:

| Переменная | Default / явный строгий выбор | Явный выбор прав на БД | Ровно один допустимый database grant |
|---|---|---|---|
| `CLRS_NATIVE_AUTH_PERMISSION_MODEL` | `strict-tables-v1` | `provider-database-v1` | `SELECT, INSERT, UPDATE ON clrs_staging.*` |
| `CLRS_LEGACY_READ_PERMISSION_MODEL` | `strict-tables-v1` | `provider-database-v1` | `SELECT ON clrs_staging.*` |

Каждый service имеет безопасную строковую метку `permission_model` для deployment evidence. Отсутствующая переменная выбирает строгую модель; пустое, неизвестное или нестроковое значение отклоняется до DB connect. Обе модели требуют отдельного `USAGE ON *.*`, принимают только свой набор прав и отказывают при других БД, global privileges, roles, GRANT OPTION, DELETE/DDL, дублях или смешении прав на БД и таблицы. Выбор permission model не включает HTTP routes, native writes или reviewed-snapshot gates. Legacy private media имеет собственный строгий parser пяти таблиц; этот выбор его не расширяет.

Для native использовать отдельного технического пользователя с ровно SELECT/INSERT/UPDATE только на `clrs_staging`; для legacy READ допускается уже согласованный `clrs_api_ro` с ровно SELECT только на этой БД. Это **согласованный opt-in**, а не эквивалент ограничению на три таблицы: скомпрометированный native сервис сможет изменять любые таблицы staging, включая accounts, credentials, source metadata и статусы медиа. Чтение через `clrs_api_ro` также распространяется на всю БД. Параметризованные запросы, account authorization и прежние snapshot/version checks сохраняются, но не уменьшают SQL полномочия при компрометации сервиса. Если такой объём прав не согласован, использовать строгие grants через поддержку Timeweb или отдельно спроектированную БД авторизации.

## Обязательный TLS и доказательство перед включением

Предпочтительно server-side **REQUIRE SSL** каждого runtime account. Для удалённого TCP runtime допустимо подтверждённое серверное `require_secure_transport=ON`: MySQL тогда отклоняет незашифрованные TCP соединения. Это не полностью совпадает с account-level REQUIRE SSL для Unix sockets; в этом runtime только TCP с обязательной CA/hostname проверкой. Настройка глобальная и динамическая, поэтому проверять её заново перед enable и после смены кластера/настроек: [MySQL require_secure_transport](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_require_secure_transport).

Фактический read-only probe 2026-10-01 с уже разрешённым migration account подтвердил MySQL **8.4.4-4**, `require_secure_transport=ON`, текущий TLS cipher и проверку CA/hostname. Ноль data/grant writes; runtime account этим probe **не проверен**. Private0600 proof: `work/private_migration_20260930/mysql84-require-secure-transport-proof-20261001.json`, SHA256 `c68a9f46556d7c9d90a97574f8c91567f1da0f1f258d623e460e30524cd56c4c`. Перед включением нужны реальные SHOW GRANTS выбранного runtime account, свежая TLS enforcement проверка, FULL/raw/profile/credential readback и controlled login; legacy требует reviewed immutable-snapshot membership.

## Конкретное действие после подтверждения владельца

1. Выбрать согласованную модель. В строгой модели создать **два** password-protected пользователя с именами выше; в provider модели создать только `clrs_native_auth`, а для legacy сначала проверить существующий `clrs_api_ro`. Отключить «Использовать одинаковые привилегии для всех баз». Первоначально никаких database-wide/table privileges не добавлять; пароль задавать/сохранять в private0600 config вне Git/APK/чата.
2. Только для строгой модели уполномоченный администратор БД сверяет username+host фактически созданных accounts и выполняет [runtime-mysql84-grants.sql](deploy/runtime-mysql84-grants.sql). Шаблон не содержит паролей/CREATE USER/revoke/DDL данных; он задаёт REQUIRE SSL и шесть exact table grants. `%` — host account template, а не право на все БД; заменить на фактический host, если Timeweb создал другой. При доступной проверенной server host restriction использовать её; неизвестный IP не угадывать.
3. Если UI позволяет только права на БД, после согласования более широкого native доступа выбрать `provider-database-v1` и ровно database grants из отдельной таблицы выше, отключив «Одинаковые для всех баз». Для legacy READ можно повторно использовать `clrs_api_ro`, если его actual SHOW GRANTS точно соответствует SELECT на `clrs_staging.*`. Строгий SQL template не превращать в database-wide grants и обе модели не смешивать. Роль `clrs_migrate` с нынешними пятью правами не может выдавать grants.
4. Прочитать SHOW GRANTS runtime пользователя и сверить выбранную модель. Отдельно подтвердить server-side REQUIRE SSL в private admin console или свежее `SHOW GLOBAL VARIABLES LIKE 'require_secure_transport'` = ON для удалённого TCP подключения. MySQL8.4 SHOW GRANTS показывает права, nonprivilege account properties находятся в SHOW CREATE USER. Его полный вывод может содержать password authentication hash; наружу сообщать только boolean `requiresSSL=true`, не строку CREATE USER. Не выдавать сервисам SELECT на `mysql.*` ради такой проверки.
5. Подключить private URLs/CA к правильным variables: `CLRS_NATIVE_AUTH_DB_URL`/`CLRS_NATIVE_AUTH_DB_CA_FILE` для первого; `CLRS_LEGACY_READ_DB_URL`/`CLRS_LEGACY_READ_DB_CA_FILE` для второго. Это следующий защищённый config/deploy шаг, не действие SQL template. DNS hostname должен совпасть с сертификатом, CA проверяется, plaintext connection запрещено.

Текст конкретного browser-confirmation для владельца строгой модели:

> Подтверждаете создание в существующей Timeweb БД двух технических пользователей `clrs_native_auth` и `clrs_legacy_read` с доступом только к перечисленным таблицам `clrs_staging` и обязательным SSL? Первый сможет читать аккаунты/данные входа и создавать/обновлять сессии; второй сможет только читать сохранённые профили и историю. Пароли сохраню отдельно от APK/Git. Новые платные ресурсы и права на другие БД не добавляются.

Для provider модели действие отличается:

> Создать `clrs_native_auth` только с SELECT/INSERT/UPDATE на `clrs_staging`; для чтения старых данных использовать проверенный `clrs_api_ro` только с SELECT на `clrs_staging`. Обязательное TLS уже подтверждено глобальной настройкой сервера, перед включением проверю её заново. Native пользователь технически сможет менять любые таблицы этой БД, а приложение будет выполнять только согласованные операции входа/сессий. Других БД, DDL, DELETE, новых платных ресурсов и ключей в Git/APK нет.

## Исправление совместимости validators и locking

`native_sessions.py` и `legacy_conversation_read.py` принимают optional exact `REQUIRE SSL` **только** на `GRANT USAGE ON *.*`. Suffix на table/database SELECT, X509, произвольные SSL options, GRANT OPTION, роли и дополнительные права по-прежнему отклоняются. Отсутствие suffix допускается для стандартного MySQL8.4 SHOW GRANTS; это не заменяет отдельное доказательство server-side TLS enforcement и текущего `Ssl_cipher`, CA и hostname. Основание: [SHOW GRANTS](https://dev.mysql.com/doc/refman/8.4/en/show-grants.html), [account TLS options](https://dev.mysql.com/doc/refman/8.4/en/create-user.html).

Перед выдачей session после KDF аккаунт и credential повторно проверяются с `FOR SHARE OF a, c`; disabled/version/password изменения не могут пройти между readback и COMMIT. Refresh/logout блокируют session `FOR UPDATE OF s` и account `FOR SHARE OF a`. В строгой модели UPDATE право остаётся только у `device_sessions`; прежний unqualified FOR UPDATE на SELECT-only accounts/credentials был несовместим с указанными правами. В provider модели SQL операций не расширяется. MySQL8.4 поддерживает mixed clauses и требует alias после OF: [SELECT syntax](https://dev.mysql.com/doc/refman/8.4/en/select.html), [locking read privileges](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html).

Адресная проверка: **46/46** тестов `test_native_auth` и `test_legacy_conversation_read` прошли с synthetic DB и official public SCRYPT vector, без пользовательских данных. Использованы существующие Python3.12, Node22 и установленный PyMySQL; новых зависимостей не ставили. Регрессии проверяют REQUIRE SSL login/read, отказ лишних suffix/scopes/прав, прежний privilege failure и правильные shared/exclusive locks, disabled/token_version recheck, existing refresh/replay/concurrency guards. Synthetic SQL model не доказывает настоящий server parser/permissions.

Новая permission-model проверка: **11/11** targeted tests (8 новых + 3 существующие регрессии) PASS. Проверены default strict, явный database opt-in, точный отказ лишних/смешанных прав и неизвестных меток до подключения, service-specific flags, неизменность enable/snapshot gates, account disabled/version readback и legacy own-membership/read-only/TLS. Широкие прогоны, реальные GRANT, UI, новые credentials и deploy не выполнялись.

После завершения текущей raw transaction отдельно выполнить реальный **zero-row SELECT** syntax probe с имеющимся TLS-клиентом, не меняя данные. Затем проверить SHOW GRANTS/TLS уже новым runtime account. Enable routes допускается только после исходного FULL/raw/profile/credential readback и controlled login прежним паролем; legacy READ дополнительно требует reviewed immutable-snapshot membership gate. Этот документ не включает public routes и не объявляет migration законченной.

Два запроса для отдельной проверки server syntax; выполнять в короткой транзакции с `ROLLBACK`, без INSERT/UPDATE/DDL. `WHERE 0` не возвращает пользовательские строки. Проверка с migration account доказывает только syntax, поэтому после выдачи exact grants повторить с `clrs_native_auth`:

```sql
SELECT a.uid, c.uid
FROM clrs_staging.accounts AS a
JOIN clrs_staging.auth_credentials AS c ON c.uid = a.uid
WHERE 0 LIMIT 1 FOR SHARE OF a, c;

SELECT s.session_id, a.uid
FROM clrs_staging.device_sessions AS s
JOIN clrs_staging.accounts AS a ON a.uid = s.uid
WHERE 0 LIMIT 1 FOR UPDATE OF s FOR SHARE OF a;
```
