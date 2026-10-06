import 'dart:async';

import 'package:wbrs/presentation/screens/list_of_users/timeweb_people_page.dart';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/presentation/screens/edit_profile/timeweb_profile_edit_page.dart';
import 'package:wbrs/presentation/screens/chat_screen/timeweb_chats_page.dart';
import 'package:wbrs/presentation/screens/profile/timeweb_own_profile_page.dart';

import 'login_screen/login_page.dart';

/// Actual native account state plus the explicitly enabled current editor (or
/// the default pinned DTO gate). Other native services/onboarding remain gated.
/// This gate never enters Firebase SessionGate/Home or hydrates legacy globals.
class TimewebSessionGate extends StatefulWidget {
  const TimewebSessionGate({super.key, required this.runtime});
  final TimewebAppRuntime runtime;
  @override
  State<TimewebSessionGate> createState() => _TimewebSessionGateState();
}

class _TimewebSessionGateState extends State<TimewebSessionGate> {
  StreamSubscription<AppSessionState>? _subscription;
  TimewebSessionProfile? _profile;
  TimewebCurrentOwnProfile? _currentOwnProfile;
  TimewebProfileEditFlow? _editor;
  TimewebCurrentReadPage? _chats;
  int? _loadedEpoch;
  int _generation = 0;
  bool _loading = false;
  bool _error = false;
  bool _showLogin = false;
  bool _hasAttemptedRead = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.runtime.session.states.listen((_) => _sync());
    _sync();
  }

  void _sync() {
    final state = widget.runtime.session.state;
    if (state.authenticated) {
      _showLogin = false;
    } else if (const {
      AppSessionPhase.signedOut,
      AppSessionPhase.failed,
      AppSessionPhase.unresolved,
      AppSessionPhase.stopped,
      AppSessionPhase.closed,
    }.contains(state.phase)) {
      _showLogin = true;
    }
    if (_loadedEpoch != state.epoch) {
      _generation++;
      _profile = null;
      _currentOwnProfile = null;
      _editor?.close();
      _editor = null;
      _chats = null;
      _loading = false;
      _error = false;
      _loadedEpoch = state.epoch;
      _hasAttemptedRead = false;
    }
    // Login changes the epoch before its identity is confirmed. Read only once
    // that same epoch becomes authenticated, even when the epoch itself stays.
    if (state.authenticated && !_hasAttemptedRead) {
      _hasAttemptedRead = true;
      unawaited(_load());
    }
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final epoch = widget.runtime.session.state.epoch;
    setState(() {
      _loading = true;
      _error = false;
      _profile = null;
      _currentOwnProfile = null;
      _editor?.close();
      _editor = null;
      _chats = null;
    });
    try {
      if (widget.runtime.ownProfileEnabled) {
        final profile = await widget.runtime.readCurrentOwnProfile();
        if (!mounted ||
            generation != _generation ||
            widget.runtime.session.state.epoch != epoch) {
          return;
        }
        profile.requireCurrent();
        setState(() => _currentOwnProfile = profile);
        return;
      }
      if (widget.runtime.profileEditorEnabled || widget.runtime.chatsEnabled) {
        TimewebProfileEditFlow? editor;
        TimewebCurrentReadPage? chats;
        var error = false;
        if (widget.runtime.chatsEnabled) {
          try {
            chats = await widget.runtime.readChats();
          } catch (_) {
            error = true;
          }
        }
        if (widget.runtime.profileEditorEnabled) {
          try {
            editor = await widget.runtime.openProfileEditor();
          } catch (_) {
            error = true;
          }
        }
        if (!mounted ||
            generation != _generation ||
            widget.runtime.session.state.epoch != epoch) {
          editor?.close();
          return;
        }
        editor?.requireCurrent();
        chats?.requireCurrent();
        setState(() {
          _editor = editor;
          _chats = chats;
          _error = error;
        });
        return;
      }
      final profile = await widget.runtime.readGateProfile();
      if (!mounted ||
          generation != _generation ||
          widget.runtime.session.state.epoch != epoch) {
        return;
      }
      profile.requireCurrent();
      setState(() => _profile = profile);
    } catch (_) {
      if (mounted &&
          generation == _generation &&
          widget.runtime.session.state.epoch == epoch) {
        setState(() => _error = true);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _editor?.close();
    unawaited(_subscription?.cancel());
    // The app owns the session. Leaving this screen is neither logout nor stop.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.runtime.session.state;
    final terminal =
        state.phase == AppSessionPhase.stopped ||
        state.phase == AppSessionPhase.closed;
    if (!terminal && _showLogin) {
      return LoginPage(nativeRuntime: widget.runtime);
    }
    if (!terminal && (!state.authenticated || _loading)) {
      return const ClrsScaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!terminal && widget.runtime.ownProfileEnabled) {
      try {
        _currentOwnProfile?.requireCurrent();
        if (_currentOwnProfile?.onboarding == TimewebOnboarding.search) {
          return TimewebPeoplePageView(
            key: ValueKey('timeweb-people-${state.epoch}-$_generation'),
            runtime: widget.runtime,
            initialOwnProfile: _currentOwnProfile,
          );
        }
      } catch (_) {
        /* Never render an old directory owner. */
      }
      return TimewebOwnProfilePage(
        key: ValueKey('timeweb-own-profile-${state.epoch}-$_generation'),
        runtime: widget.runtime,
        initialProfile: _currentOwnProfile,
        initialError: _error,
      );
    }
    String? stage;
    TimewebProfileEditFlow? editor;
    TimewebCurrentReadPage? chats;
    try {
      stage = _profile?.onboarding.name;
      _editor?.requireCurrent();
      if (!terminal) editor = _editor;
      _chats?.requireCurrent();
      if (!terminal) chats = _chats;
    } catch (_) {
      // A queued rebuild must not render an old A snapshot after a B intent.
    }
    return ClrsScaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ClrsPanel(
              key: ValueKey('timeweb-gate-${stage ?? 'unavailable'}'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.tr(
                      editor != null
                          ? 'Редактировать профиль'
                          : chats != null
                          ? 'Чаты'
                          : 'Профиль недоступен',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.tr(
                      _error
                          ? 'Не удалось загрузить профиль. Проверьте соединение и повторите попытку.'
                          : 'Сервис пока недоступен. Попробуйте позднее.',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (chats != null)
                    ElevatedButton(
                      key: const ValueKey('timeweb-open-chats'),
                      onPressed: () async {
                        final current = chats!;
                        final epoch = state.epoch;
                        current.requireCurrent();
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            settings: const RouteSettings(
                              name: timewebChatsRoute,
                            ),
                            builder: (_) => TimewebChatsPage(
                              runtime: widget.runtime,
                              initialPage: current,
                            ),
                          ),
                        );
                        if (mounted &&
                            widget.runtime.session.state.authenticated &&
                            widget.runtime.session.state.epoch == epoch) {
                          await _load();
                        }
                      },
                      child: Text(context.tr('Чаты')),
                    ),
                  if (editor != null)
                    ElevatedButton(
                      key: const ValueKey('timeweb-open-profile-editor'),
                      onPressed: () async {
                        final current = editor!;
                        final epoch = state.epoch;
                        current.requireCurrent();
                        await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) =>
                                TimewebProfileEditPage(flow: current),
                          ),
                        );
                        if (mounted &&
                            widget.runtime.session.state.authenticated &&
                            widget.runtime.session.state.epoch == epoch) {
                          await _load();
                        }
                      },
                      child: Text(context.tr('Редактировать профиль')),
                    ),
                  TextButton(
                    onPressed: terminal ? null : _load,
                    child: Text(context.tr('Повторить')),
                  ),
                  TextButton(
                    onPressed: terminal
                        ? null
                        : () async {
                            await widget.runtime.session.logout();
                            if (mounted) _sync();
                          },
                    child: Text(context.tr('Вернуться ко входу')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
