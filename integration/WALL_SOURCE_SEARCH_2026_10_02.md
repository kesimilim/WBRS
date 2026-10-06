# Поиск исходников стены Ксюши — 2026-10-02

Отдельная стена Ксюши не найдена в доступных исходниках. В нашей интеграции
стена и лента присутствуют. Их нельзя выдавать за независимо подтверждённую
работу Ксюши. Это результат поиска источника, а не приёмка стены или завершение
переезда на Timeweb.

## Актуальный снимок GitHub

Выполнены авторизованные `ls-remote` и один `fetch` в отдельные проверочные
refs исходного `4eKHyTblyi/WBRS`. Рабочая ветка и файлы приложения не менялись.
`SOQPS/WBRS` является fork с двумя ветками и не заменяет проверку исходного
репозитория.

| Ветка исходного проекта | SHA |
| --- | --- |
| check-git | `df49f48fd3e75e2b315b3f9e443a30b3a1fb01a7` |
| dev | `df49f48fd3e75e2b315b3f9e443a30b3a1fb01a7` |
| for-test | `9e65230dc7e0d255ee3a804b2d93d1e09fc9e091` |
| git | `df49f48fd3e75e2b315b3f9e443a30b3a1fb01a7` |
| main | `9ba1be22b92e7451482ec2192c15ce5a33b174c1` |
| prod | `b146a0d0fe1db352c934681ccc5b73db7d9ccd25` |
| refactor-all-code | `4db1bdabcb5a6978d1140a65449b9cc918ee7e16` |

| PR head ref | SHA |
| --- | --- |
| refs/pull/1/head | `c28390dc207bef19230bad6665ae0510ad6cd86a` |
| refs/pull/2/head | `2766214e616f8b32f8f957bb43c295d49f9fde74` |
| refs/pull/3/head | `e835def8efbff0b3021bf9415851d263c4c573bc` |
| refs/pull/4/head | `3c2f7f5115ad8688134c02c320d146db7fab4737` |

Имена файлов, содержимое Dart/rules и история коммитов проверены во всех этих
refs. В семи исходных ветках и PR 1–3 реализации стены/ленты не обнаружены;
`ProfileWallPage`, `FeedPage` и соответствующий социальный сервис находятся
в нашей PR 4. Новых PR head refs после PR 4 на момент проверки нет.

## Подтверждённый commit Ксюши

В доступной истории найден один commit автора `kesimilim`:
`e835def8efbff0b3021bf9415851d263c4c573bc`, 2026-09-18, `Fix robokassa`, PR 3.
Он меняет следующие файлы:

- `lib/app/widgets/bottom_nav_bar.dart`
- `lib/app/widgets/donate_button.dart`
- `lib/app/widgets/drawer.dart`
- `lib/app/widgets/glass_button.dart`
- `lib/app/widgets/oplata.dart`
- `lib/app/widgets/robokassa_webview.dart`
- `lib/app/widgets/widgets.dart`
- `lib/presentation/screens/shop/shop.dart`

В этом commit нет реализации стены или ленты. Платёжные файлы при поиске не
изменялись. Социальные исходники импортированы в `3431d85` из проверенного
архива интеграции, затем изменялись в `e4f1faa`, `87eb8fc` и `9eb909a`; эта история
не подтверждает авторство Ксюши.

## Доступные исходные архивы и сборки

Проверен 21 исходный ZIP под `outputs/` и `artifacts/`: перечисление файлов
и SHA-256 содержимого `profile_wall_page.dart`/`feed_page.dart` без распаковки
архивов и декомпиляции APK. Следующие пути относительны к рабочему каталогу `ds`:

| Архив | Найденные исходники |
| --- | --- |
| `outputs/CLRS_QA_corrected.zip` | feed, без profile wall |
| `outputs/stage2-1.0.8/CLRS-1.0.8-source.zip` | wall + feed |
| `outputs/translation-1.0.9/CLRS-1.0.9-source.zip` | wall + feed |
| `outputs/priority-1.0.11/CLRS-1.0.11-source.zip` | wall + feed |
| `outputs/session-performance-1.0.12/CLRS-1.0.12-source.zip` | wall + feed |
| `outputs/dmitry-final-1.0.17/CLRS-1.0.17-sources.zip` | wall + feed |
| `outputs/google-attribution-1.0.18/CLRS-1.0.18-sources.zip` | wall + feed |
| `artifacts/amazon_translate_2026-09-25/CLRS_Amazon_Translate_sources.zip` | wall + feed |
| `artifacts/clrs_features_2026-09-28/CLRS-1.0.20-34-sources.zip` | wall + feed |
| `artifacts/clrs_features_1_0_21_2026-09-28/CLRS-1.0.21-35-sources.zip` | wall + feed |
| `artifacts/clrs_github_integration_2026-09-28/CLRS-1.0.21-35-github-client.zip` | wall + feed |
| `artifacts/clrs_dmitry_feedback_2026-09-28/CLRS-1.0.22-36-sources.zip` | wall + feed |
| `artifacts/clrs_dmitry_feedback_2026-09-28/CLRS-1.0.22-36-gitlab-client.zip` | wall + feed |
| `artifacts/clrs_bunny_heading_2026-09-28/CLRS-1.0.23-37-sources.zip` | wall + feed |
| `artifacts/clrs_bunny_heading_2026-09-28/CLRS-1.0.23-37-gitlab-client.zip` | wall + feed |
| `artifacts/clrs_firebase_access_2026-09-28/CLRS-1.0.24-38-sources.zip` | wall + feed |
| `artifacts/clrs_feature_completion_2026-09-28/CLRS-1.0.25-39-sources.zip` | wall + feed |
| `artifacts/clrs_github_integration_2026-09-30/CLRS-1.0.25-39-github-integration-source.zip` | wall + feed |
| `artifacts/clrs_github_integration_2026-09-30/CLRS-1.0.25-39-gifts-chat-review-source.zip` | wall + feed |
| `artifacts/clrs_github_integration_2026-09-30/CLRS-1.0.25-39-gifts-wall-review-source.zip` | wall + feed |
| `artifacts/clrs_2026-09-30_1.0.25-40/CLRS-1.0.25-40-source.zip` | wall + feed |

Архивы содержат последовательные версии интеграции; независимый источник
Ксюши не идентифицирован. Для APK 41–43 дополнительно сопоставлены сохранённые
build bindings с соответствующими Git source commits. Оба файла одинаковы
в этих трёх commits и в проверенной текущей интеграции:

- `lib/presentation/screens/feed/profile_wall_page.dart` SHA-256:
  `7f3e3bcb16dbd3b12711c355ea47b816456ec37850d0c78a0d0bd5839f5e9d31`.
- `lib/presentation/screens/feed/feed_page.dart` SHA-256:
  `300a20c9f29f3e2790ffcb197174b8a9bac2a27493aafb9545dc18f9402f8cd8`.

| Version code | Сохранённый source commit |
| --- | --- |
| 41 | `9eb909a2704952294d8ee0336cb9d52fff6f7461` |
| 42 | `2eacfefc6996d8364c7166d574c1701fe73e1dc7` |
| 43 | `54818583bf33116e798fa5975a392a1de8cc7a3f` |

`artifacts/clrs_final_20261002/release43-build-binding.json` содержит оба
указанных file hashes, `trackedApkInputsMatchCommit: true` и APK SHA-256
`ed93ff4af751c4dcdc2c5083d5e94c3bf7690933d310236208fdd6d8c4f35db3`.
Это связь сохранённой сборки с исходниками, а не новый запуск APK или проверка
живых аккаунтов. Поиск не охватывает другой репозиторий, неопубликованный код
или APK без доступных исходников/binding. Новые тесты, сборки, cloud изменения,
push и merge для этого поиска не выполнялись.
