import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wbrs/app/pages/policy/confidecialnost.dart';
import 'package:wbrs/app/pages/policy/offer.dart';
import 'package:wbrs/app/pages/policy/soglashenie.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/language_picker.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_lifecycle.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_preferences_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/rules_content.dart';
import 'package:wbrs/shared/timeweb_email_lifecycle_form.dart';
import 'package:wbrs/shared/timeweb_bottom_navigation.dart';

const timewebAccountRoute = '/timeweb/settings';

enum TimewebAccountAction { editProfile }

enum _View { settings, about, help, privacy, rules, offer, agreement, password }

/// Native account navigation reuses the approved static CLRS composition. Each
/// pushed route captures this same runtime's owner; it grants no extra access.
class TimewebAccountPage extends StatefulWidget {
  const TimewebAccountPage({
    super.key,
    required this.runtime,
    required this.lease,
    this.canEditProfile = false,
  }) : _view = _View.settings;
  const TimewebAccountPage.about({
    super.key,
    required this.runtime,
    required this.lease,
  }) : canEditProfile = false,
       _view = _View.about;
  const TimewebAccountPage._({
    required this.runtime,
    required this.lease,
    required _View view,
    required this.canEditProfile,
  }) : _view = view;
  final TimewebAppRuntime runtime;
  final AppSessionLease lease;
  final bool canEditProfile;
  final _View _view;
  @override
  State<TimewebAccountPage> createState() => _TimewebAccountPageState();
}

class _TimewebAccountPageState extends State<TimewebAccountPage> {
  late final AppSessionLease _lease;
  StreamSubscription<AppSessionState>? _states;
  TimewebAuthLifecycleClient? _email;
  TimewebPreferencesFlow? _preferencesFlow;
  TimewebPreferences? _preferences;
  bool? _messages, _meetings, _sound;
  bool _preferencesLoading = false, _preferencesBusy = false;
  String? _preferencesNotice;
  bool _invalidated = false, _busy = false;
  String? _notice;
  bool get _current {
    if (!mounted || _invalidated) return false;
    try {
      _lease.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _lease = widget.lease;
    try {
      _lease.requireCurrent();
    } catch (_) {
      _invalidated = true;
    }
    if (!_invalidated && widget._view == _View.password) {
      _email = widget.runtime.createEmailLifecycleClient(
        TimewebLifecyclePurpose.passwordReset,
      );
    }
    if (!_invalidated && widget._view == _View.settings) {
      unawaited(_loadPreferences());
    }
    _states = widget.runtime.session.states.listen((_) {
      if (_current || _invalidated) return;
      _invalidated = true;
      _notice = null;
      _clearPreferences();
      unawaited(_email?.close());
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route != null && route.isActive && !route.isFirst) {
          Navigator.of(context).removeRoute(route);
        }
      });
    });
  }

  @override
  void dispose() {
    _invalidated = true;
    _clearPreferences();
    unawaited(_states?.cancel());
    unawaited(_email?.close());
    super.dispose();
  }

  void _clearPreferences() {
    _preferencesFlow?.close();
    _preferencesFlow = null;
    _preferences = null;
    _messages = _meetings = _sound = null;
    _preferencesNotice = null;
    _preferencesLoading = _preferencesBusy = false;
  }

  bool get _preferencesPending =>
      _current && (_preferencesFlow?.needsCheck ?? false);
  void _usePreferences(TimewebPreferences value) {
    value.requireCurrent();
    _preferences = value;
    _messages = value.messages;
    _meetings = value.meetings;
    _sound = value.sound;
  }

  Future<void> _loadPreferences() async {
    if (!_current || _preferencesLoading || _preferencesBusy) return;
    setState(() {
      _preferencesLoading = true;
      _preferencesNotice = null;
    });
    TimewebPreferencesFlow? flow;
    try {
      flow = await widget.runtime.openPreferences();
      if (!_current) return;
      final pending = flow.pendingAction;
      final value = pending == null
          ? await widget.runtime.readPreferences()
          : null;
      if (!_current) return;
      _preferencesFlow?.close();
      _preferencesFlow = flow;
      flow = null;
      setState(() {
        if (value != null) {
          _usePreferences(value);
        } else {
          _messages = pending!.messages;
          _meetings = pending.meetings;
          _sound = pending.sound;
          _preferencesNotice =
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.';
        }
      });
    } catch (_) {
      if (_current) {
        setState(
          () => _preferencesNotice =
              'Сервис пока недоступен. Попробуйте позднее.',
        );
      }
    } finally {
      flow?.close();
      if (_current) setState(() => _preferencesLoading = false);
    }
  }

  Future<void> _savePreferences() async {
    final flow = _preferencesFlow;
    if (!_current || flow == null || _preferencesBusy || _preferencesLoading) {
      return;
    }
    setState(() {
      _preferencesBusy = true;
      _preferencesNotice = null;
    });
    try {
      final result =
          await (flow.needsCheck
                  ? flow.check()
                  : flow.submit(
                      TimewebPreferenceChanges(
                        expectedRevision: _preferences!.revision,
                        messages: _messages!,
                        meetings: _meetings!,
                        sound: _sound!,
                      ),
                    ))
              .timeout(flow.observationTimeout);
      if (!_current) return;
      if (result == TimewebPreferencesOutcome.confirmed) {
        flow.receipt!.requireCurrent();
        // A recovered receipt proves the original save. It can precede a
        // later save on another device, so controls use a fresh current GET.
        setState(() {
          _preferences = null;
          _messages = _meetings = _sound = null;
        });
        final value = await widget.runtime.readPreferences();
        if (_current) setState(() => _usePreferences(value));
      } else if (result == TimewebPreferencesOutcome.rejected) {
        setState(() {
          _preferences = null;
          _messages = _meetings = _sound = null;
        });
        final value = await widget.runtime.readPreferences();
        if (_current) {
          setState(() {
            _usePreferences(value);
            _preferencesNotice =
                'Не удалось сохранить изменения. Попробуйте ещё раз.';
          });
        }
      } else {
        setState(
          () => _preferencesNotice =
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _preferencesNotice = flow.needsCheck
              ? 'Подтверждение ещё не получено. Проверьте результат без повторной отправки.'
              : 'Сервис пока недоступен. Попробуйте позднее.',
        );
      }
    } finally {
      if (_current) setState(() => _preferencesBusy = false);
    }
  }

  Widget _preference(
    String key,
    String label,
    IconData icon,
    bool value,
    ValueChanged<bool> change,
  ) => SwitchListTile.adaptive(
    key: ValueKey('timeweb-preferences-$key'),
    dense: true,
    visualDensity: const VisualDensity(vertical: -2),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    secondary: Icon(icon, color: LrsTheme.peachLight, size: 21),
    title: Text(
      context.tr(label),
      style: const TextStyle(fontFamily: 'Lato', fontSize: 14),
    ),
    value: value,
    activeTrackColor: LrsTheme.peach,
    onChanged:
        _preferencesBusy ||
            _preferencesLoading ||
            _preferencesPending ||
            _preferences == null
        ? null
        : change,
  );
  Widget _preferencesGroup() => _group('Уведомления', [
    if (_preferencesLoading || _preferencesBusy)
      const LinearProgressIndicator(),
    if (_messages != null) ...[
      _preference(
        'messages',
        'Сообщения',
        Icons.chat_bubble_outline,
        _messages!,
        (value) => setState(() => _messages = value),
      ),
      _preference(
        'meetings',
        'Встречи',
        Icons.event_outlined,
        _meetings!,
        (value) => setState(() => _meetings = value),
      ),
      _preference(
        'sound',
        'Звук уведомлений',
        Icons.notifications_none,
        _sound!,
        (value) => setState(() => _sound = value),
      ),
      TextButton(
        key: const ValueKey('timeweb-preferences-save'),
        onPressed:
            _preferencesBusy ||
                _preferencesLoading ||
                (!_preferencesPending &&
                    (_preferences == null ||
                        _preferences!.messages == _messages &&
                            _preferences!.meetings == _meetings &&
                            _preferences!.sound == _sound))
            ? null
            : _savePreferences,
        child: Text(
          context.tr(
            _preferencesPending ? 'Проверить результат' : 'Сохранить настройки',
          ),
        ),
      ),
    ],
    if (_preferencesNotice != null)
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text(context.tr(_preferencesNotice!)),
      ),
    if (!_preferencesLoading && _messages == null)
      TextButton(
        key: const ValueKey('timeweb-preferences-retry'),
        onPressed: _loadPreferences,
        child: Text(context.tr('Повторить')),
      ),
  ]);

  Future<void> _open(_View view) async {
    if (!_current || _busy || ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final page = TimewebNavigationScope.wrap(
      context,
      TimewebAccountPage._(
        runtime: widget.runtime,
        lease: _lease,
        view: view,
        canEditProfile: widget.canEditProfile,
      ),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: RouteSettings(name: '$timewebAccountRoute/${view.name}'),
        builder: (_) => page,
      ),
    );
  }

  Future<void> _logout() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await widget.runtime.session.logout();
    } catch (_) {
      if (_current) {
        setState(() => _notice = 'Сервис пока недоступен. Попробуйте позднее.');
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _support() async {
    if (!_current) return;
    var opened = false;
    try {
      opened = await launchUrl(Uri(scheme: 'mailto', path: 'supp.lrs@ya.ru'));
    } catch (_) {}
    if (opened || !mounted || !_current) return;
    // Existing public support address remains available without a mail handler.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const SelectableText('supp.lrs@ya.ru'),
        action: SnackBarAction(
          label: context.tr('Копировать'),
          onPressed: () {
            if (_current) {
              unawaited(
                Clipboard.setData(const ClipboardData(text: 'supp.lrs@ya.ru')),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _row(String key, IconData icon, String label, VoidCallback? onTap) =>
      ListTile(
        key: ValueKey(key),
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(icon, color: LrsTheme.peachLight, size: 21),
        title: Text(
          context.tr(label),
          style: const TextStyle(fontFamily: 'Lato', fontSize: 14),
        ),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: onTap,
      );
  Widget _group(String title, List<Widget> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Text(
          context.tr(title),
          style: const TextStyle(
            color: LrsTheme.peachLight,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      ClrsPanel(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14),
              rows[i],
            ],
          ],
        ),
      ),
    ],
  );
  Widget _settingsHeader() => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ClrsLogo(size: 27, subtitle: false),
          Text(
            context.tr('Ближе к настоящему'),
            style: const TextStyle(fontSize: 8, color: LrsTheme.peachLight),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: LrsTheme.actionGlass,
                  shape: BoxShape.circle,
                  border: Border.all(color: LrsTheme.actionBorder),
                ),
                child: IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.tr('Настройки'),
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _settings() => Column(
    children: [
      _settingsHeader(),
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) {
            final width = MediaQuery.textScalerOf(context).scale(14) > 20
                ? box.maxWidth - 32
                : (box.maxWidth - 32) * .76;
            return SingleChildScrollView(
              key: const ValueKey('timeweb-settings-scroll'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _group('Аккаунт', [
                        _row(
                          'timeweb-settings-personal',
                          Icons.person_outline,
                          'Личные данные',
                          widget.canEditProfile
                              ? () {
                                  if (_current) {
                                    Navigator.of(
                                      context,
                                    ).pop(TimewebAccountAction.editProfile);
                                  }
                                }
                              : null,
                        ),
                        _row(
                          'timeweb-settings-password',
                          Icons.lock_outline,
                          'Сменить пароль',
                          () => _open(_View.password),
                        ),
                        _row(
                          'timeweb-settings-privacy',
                          Icons.shield_outlined,
                          'Конфиденциальность',
                          () => _open(_View.privacy),
                        ),
                      ]),
                      _preferencesGroup(),
                      _group('Помощь', [
                        _row(
                          'timeweb-settings-about',
                          Icons.info_outline,
                          'О приложении',
                          () => _open(_View.about),
                        ),
                        _row(
                          'timeweb-settings-rules',
                          Icons.description_outlined,
                          'Правила сообщества',
                          () => _open(_View.rules),
                        ),
                        _row(
                          'timeweb-settings-support',
                          Icons.support_agent_outlined,
                          'Связаться с поддержкой',
                          _support,
                        ),
                      ]),
                      const SizedBox(height: 16),
                      ClrsPanel(
                        key: const ValueKey('timeweb-settings-language'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.language,
                              size: 20,
                              color: LrsTheme.peach,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.tr('Язык'),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const LanguagePickerButton(showIcon: false),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      ClrsPanel(
                        padding: EdgeInsets.zero,
                        child: TextButton.icon(
                          key: const ValueKey('timeweb-settings-logout'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(double.infinity, 42),
                            foregroundColor: LrsTheme.peachLight,
                          ),
                          onPressed: _busy ? null : _logout,
                          icon: const Icon(Icons.logout, size: 20),
                          label: Text(context.tr('Выйти из аккаунта')),
                        ),
                      ),
                      if (_notice != null) Text(context.tr(_notice!)),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
  Widget _legalRow(String key, IconData icon, String label, _View view) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: ClrsPanel(
          padding: EdgeInsets.zero,
          child: InkWell(
            key: ValueKey(key),
            borderRadius: BorderRadius.circular(18),
            onTap: () => _open(view),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(icon, color: LrsTheme.peach, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.tr(label),
                      style: const TextStyle(fontSize: 12, height: 1.15),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          ),
        ),
      );
  Widget _about() => LayoutBuilder(
    builder: (context, box) {
      final available = (box.maxWidth - 28).clamp(0.0, double.infinity);
      final panelWidth = available * .64;
      final detailWidth = available * .76;
      return ListView(
        key: const ValueKey('timeweb-about-scroll'),
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        children: [
          const ClrsLogo(size: 48),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 205,
              child: Text(
                context.tr(ClrsBrand.ruTagline),
                style: const TextStyle(fontSize: 10, height: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 125,
              child: Column(
                children: [
                  ClrsMotto(size: 19),
                  Icon(Icons.favorite_border, color: LrsTheme.peach, size: 19),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr('О приложении'),
            style: const TextStyle(
              fontFamily: 'CormorantGaramond',
              fontWeight: FontWeight.w600,
              fontSize: 28,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: panelWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _legalRow(
                    'timeweb-about-privacy',
                    Icons.shield_outlined,
                    'Политика конфиденциальности',
                    _View.privacy,
                  ),
                  _legalRow(
                    'timeweb-about-agreement',
                    Icons.description_outlined,
                    'Пользовательское соглашение',
                    _View.agreement,
                  ),
                  _legalRow(
                    'timeweb-about-offer',
                    Icons.handshake_outlined,
                    'Публичная оферта',
                    _View.offer,
                  ),
                  _legalRow(
                    'timeweb-about-rules',
                    Icons.menu_book_outlined,
                    'Правила использования',
                    _View.rules,
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: detailWidth,
              child: Column(
                children: [
                  ClrsPanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 20,
                          color: LrsTheme.peach,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.tr('Версия приложения'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const Text('1.0.25', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 5),
                        const Icon(Icons.chevron_right, size: 20),
                      ],
                    ),
                  ),
                  const SizedBox(height: 5),
                  ClrsPanel(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      key: const ValueKey('timeweb-about-support'),
                      dense: true,
                      minTileHeight: 40,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ),
                      leading: const Icon(Icons.chat_bubble_outline, size: 20),
                      horizontalTitleGap: 8,
                      title: Text(
                        context.tr('Обратная связь'),
                        style: const TextStyle(
                          fontFamily: 'Lato',
                          fontSize: 12,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: _support,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: detailWidth,
              child: ClrsPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.language, size: 20, color: LrsTheme.peach),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.tr('Язык'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const LanguagePickerButton(showIcon: false),
                  ],
                ),
              ),
            ),
          ),
          const ClrsValuesFooter(compact: true),
        ],
      );
    },
  );
  Widget _help() => LayoutBuilder(
    builder: (context, box) {
      final available = box.maxWidth - 28;
      final width = MediaQuery.textScalerOf(context).scale(14) > 20
          ? available
          : available * .76;
      return ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const ClrsBrandHeader(),
          Text(
            context.tr('Помощь'),
            style: const TextStyle(
              fontSize: 28,
              fontFamily: 'CormorantGaramond',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: width,
              child: _group('Помощь', [
                _row(
                  'timeweb-help-support',
                  Icons.support_agent_outlined,
                  'Связаться с поддержкой',
                  _support,
                ),
                _row(
                  'timeweb-help-rules',
                  Icons.description_outlined,
                  'Правила сообщества',
                  () => _open(_View.rules),
                ),
                _row(
                  'timeweb-help-about',
                  Icons.info_outline,
                  'О приложении',
                  () => _open(_View.about),
                ),
              ]),
            ),
          ),
          const ClrsValuesFooter(compact: true),
        ],
      );
    },
  );
  Widget _rules() => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: MediaQuery.textScalerOf(context).scale(14) > 20
              ? box.maxWidth - 28
              : (box.maxWidth - 28) * .64,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ClrsBrandHeader(),
              ClrsPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('Правила использования'),
                      style: const TextStyle(
                        fontSize: 28,
                        fontFamily: 'CormorantGaramond',
                      ),
                    ),
                    for (final chapter in rulesChapters) ...[
                      const Divider(height: 28),
                      Text(
                        context.tr(chapter.title),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      for (var i = 0; i < chapter.items.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '${i + 1}. ${context.tr(chapter.items[i])}',
                            style: const TextStyle(fontSize: 14, height: 1.35),
                          ),
                        ),
                      if (chapter == rulesChapters[1])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            context.tr(rulesThanks),
                            style: const TextStyle(fontSize: 13, height: 1.4),
                          ),
                        ),
                    ],
                    const ClrsValuesFooter(compact: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return ClrsScaffold(
        body: Center(child: Text(context.tr('Сеанс завершён'))),
      );
    }
    switch (widget._view) {
      case _View.privacy:
        return const Politica();
      case _View.offer:
        return const Offer();
      case _View.agreement:
        return const Rules();
      default:
        break;
    }
    final settings = widget._view == _View.settings;
    final about = widget._view == _View.about;
    return ClrsScaffold(
      backgroundAsset: about
          ? 'assets/family_main.jpg'
          : settings
          ? 'assets/final_design/house.png'
          : 'assets/final_design/family_right.png',
      backgroundScale: about ? 1.42 : 1,
      bottomNavigationBar: const TimewebBottomNavigationBar(),
      appBar: settings
          ? null
          : AppBar(
              actions: about
                  ? const [
                      Padding(
                        padding: EdgeInsets.only(right: 16),
                        child: Icon(
                          Icons.favorite_border,
                          color: LrsTheme.peach,
                        ),
                      ),
                    ]
                  : const [
                      Icon(Icons.favorite_border, color: LrsTheme.peachLight),
                      SizedBox(width: 14),
                    ],
            ),
      body: switch (widget._view) {
        _View.settings => _settings(),
        _View.about => _about(),
        _View.help => _help(),
        _View.rules => _rules(),
        _View.password => ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const ClrsBrandHeader(),
            Text(
              context.tr('Сменить пароль'),
              style: const TextStyle(fontSize: 25),
            ),
            const SizedBox(height: 12),
            ClrsPanel(
              child: TimewebEmailLifecycleForm(
                client: _email,
                purpose: TimewebLifecyclePurpose.passwordReset,
              ),
            ),
          ],
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}
