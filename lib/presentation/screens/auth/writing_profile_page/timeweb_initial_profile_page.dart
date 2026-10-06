import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_initial_profile_flow.dart';
import 'package:wbrs/service/timeweb_photo_upload_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';

const timewebInitialProfileRoute = '/timeweb/initial-profile';

/// Initial own fields + three actual native upload receipts. No Firebase state.
class TimewebInitialProfilePage extends StatefulWidget {
  const TimewebInitialProfilePage({super.key, required this.runtime, required this.initialProfile, this.pickPhoto});
  final TimewebAppRuntime runtime;
  final TimewebCurrentOwnProfile initialProfile;
  final Future<XFile?> Function()? pickPhoto;
  @override
  State<TimewebInitialProfilePage> createState() => _TimewebInitialProfilePageState();
}

class _TimewebInitialProfilePageState extends State<TimewebInitialProfilePage> {
  final _form = GlobalKey<FormState>();
  final _fields = {
    for (final name in ['fullName', 'age', 'rost', 'about', 'hobbi']) name: TextEditingController(),
  };
  final _menus = GlobalKey<NavigatorState>();
  final _render = ValueNotifier<int>(0);
  StreamSubscription<AppSessionState>? _subscription;
  TimewebInitialProfileFlow? _flow;
  TimewebPhotoUploadFlow? _upload;
  List<GeoCountry> _countries = [];
  String? _country, _region, _gender, _relation, _notice;
  bool? _children;
  late final int _epoch;
  bool _busy = true, _invalidated = false;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    try {
      widget.initialProfile.requireCurrent();
      final profile = widget.initialProfile.profile;
      if (profile != null) {
        _fill(
          {
            'fullName': profile.fullName,
            'age': profile.age,
            'rost': profile.rost,
            'about': profile.about,
            'hobbi': profile.hobbi,
            'deti': profile.deti,
            'pol': profile.pol,
            'relationStatus': profile.relationStatus,
          },
          profile.countryCode,
          profile.region,
        );
      }
    } catch (_) {
      _invalidated = true;
    }
    _subscription = widget.runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    if (!_invalidated) unawaited(_open());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  bool get _current {
    if (!mounted ||
        _invalidated ||
        !widget.runtime.session.state.authenticated ||
        widget.runtime.session.state.epoch != _epoch)
      return false;
    try {
      widget.initialProfile.requireCurrent();
      _flow?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _update(VoidCallback change) {
    if (!mounted) return;
    setState(change);
    _render.value++;
  }

  void _fill(Map<String, dynamic> values, String? country, String? region) {
    for (final name in _fields.keys) {
      _fields[name]!.text = values[name]?.toString() ?? '';
    }
    _children = values['deti'] as bool?;
    _gender = values['pol'] as String?;
    _relation = values['relationStatus'] as String?;
    _country = country;
    _region = region;
  }

  Future<void> _open() async {
    try {
      final flow = await widget.runtime.openInitialProfile();
      if (!_current) {
        flow.close();
        return;
      }
      _flow = flow;
      final profile = widget.initialProfile.profile;
      if (!flow.needsCheck &&
          (profile?.profileDetailsSaved != false ||
              profile?.isRegistrationEnd != false ||
              widget.initialProfile.onboarding == TimewebOnboarding.search)) {
        flow.close();
        _flow = null;
        _notice = 'Сервис пока недоступен. Попробуйте позднее.';
        return;
      }
      final pending = flow.pendingRequest;
      if (pending != null) _fill(pending.changes, pending.countryCode, pending.region);
      final countries = await GeoCatalog.load();
      if (!_current) return;
      _countries = countries;
      if (!flow.needsCheck) {
        _upload = await widget.runtime.openPhotoUpload(onReady: flow.addReadyPhoto);
        if (!_current) {
          await _upload?.close();
          _upload = null;
          return;
        }
      }
    } catch (_) {
      if (_current) _notice = 'Сервис пока недоступен. Попробуйте позднее.';
    } finally {
      if (mounted) _update(() => _busy = false);
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    for (final controller in _fields.values) {
      controller.clear();
    }
    _children = null;
    _country = null;
    _region = null;
    _gender = null;
    _relation = null;
    _notice = null;
    _flow?.close();
    _flow = null;
    unawaited(_upload?.close() ?? Future<void>.value());
    _upload = null;
    _update(() => _busy = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _menus.currentState?.popUntil((route) => route.isFirst);
      final route = _route;
      if (mounted && route != null && route.isActive && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<TimewebProfilePhotoSource?> _choose() async {
    final file = await (widget.pickPhoto?.call() ?? ImagePicker().pickImage(source: ImageSource.gallery));
    if (!_current || file == null) return null;
    if (await file.length() > 5242880) throw const FormatException('Photo is too large.');
    final buffer = Uint8List(5242881);
    var length = 0;
    try {
      await for (final bytes in file.openRead()) {
        if (!_current || length + bytes.length > 5242880) throw const FormatException('Photo changed.');
        buffer.setRange(length, length + bytes.length, bytes);
        length += bytes.length;
      }
      if (!_current) return null;
      final mime = length >= 8 && buffer[0] == 137 && buffer[1] == 80 && buffer[2] == 78 && buffer[3] == 71
          ? 'image/png'
          : length >= 3 && buffer[0] == 255 && buffer[1] == 216 && buffer[2] == 255
          ? 'image/jpeg'
          : length >= 12 &&
                String.fromCharCodes(buffer.sublist(0, 4)) == 'RIFF' &&
                String.fromCharCodes(buffer.sublist(8, 12)) == 'WEBP'
          ? 'image/webp'
          : null;
      if (mime == null) throw const FormatException('Photo format is unsupported.');
      return TimewebProfilePhotoSource.fromBytes(Uint8List.sublistView(buffer, 0, length), mimeType: mime);
    } finally {
      buffer.fillRange(0, buffer.length, 0);
    }
  }

  Future<void> _addPhoto() async {
    final upload = _upload, flow = _flow;
    if (!_current ||
        _busy ||
        upload == null ||
        flow == null ||
        flow.needsCheck ||
        flow.readyPhotos.length >= 3 ||
        upload.needsCheck)
      return;
    _update(() {
      _busy = true;
      _notice = null;
    });
    TimewebProfilePhotoSource? source;
    try {
      source = await _choose();
      if (!_current || source == null) {
        source?.close();
        return;
      }
      if (upload.metadata == null) {
        final outcome = await upload.prepare(source).timeout(upload.observationTimeout);
        if (!_current) return;
        if (outcome != TimewebPhotoUploadOutcome.prepared) {
          await _photoResult(outcome);
          return;
        }
      } else {
        upload.reattach(source);
      }
      source = null; // The upload flow owns and clears its private copy.
      final outcome = await upload.uploadAndCommit().timeout(upload.observationTimeout);
      if (_current) await _photoResult(outcome);
    } catch (_) {
      source?.close();
      if (_current) _unknown();
    } finally {
      if (mounted) _update(() => _busy = false);
    }
  }

  void _unknown() => _notice = 'Результат пока не подтверждён. Нажмите «Проверить результат».';

  Future<void> _photoResult(TimewebPhotoUploadOutcome outcome) async {
    if (outcome != TimewebPhotoUploadOutcome.ready) {
      if (outcome == TimewebPhotoUploadOutcome.rejected) {
        await _upload?.close();
        if (!_current) return;
        _upload = await widget.runtime.openPhotoUpload(onReady: _flow!.addReadyPhoto);
        if (!_current) {
          await _upload?.close();
          _upload = null;
          return;
        }
        _notice = 'Сервис пока недоступен. Попробуйте позднее.';
      } else {
        _unknown();
      }
      return;
    }
    await _upload?.close();
    if (!_current) return;
    _upload = await widget.runtime.openPhotoUpload(onReady: _flow!.addReadyPhoto);
    if (!_current) {
      await _upload?.close();
      _upload = null;
      return;
    }
    if (_flow!.readyPhotos.length == 3) await _flow!.checkPhotos().timeout(_flow!.observationTimeout);
  }

  Future<void> _checkPhoto() async {
    final flow = _flow, upload = _upload;
    if (!_current || _busy || flow == null || flow.needsCheck) return;
    _update(() {
      _busy = true;
      _notice = null;
    });
    try {
      if (upload != null && upload.metadata != null) {
        final outcome = await upload.check().timeout(upload.observationTimeout);
        if (_current) await _photoResult(outcome);
      } else {
        await flow.checkPhotos().timeout(flow.observationTimeout);
      }
    } catch (_) {
      if (_current) _unknown();
    } finally {
      if (mounted) _update(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final flow = _flow;
    if (!_current || _busy || flow == null) return;
    final pending = flow.needsCheck;
    if (!pending &&
        (flow.readyPhotos.length != 3 ||
            !flow.photosVerified ||
            _upload?.metadata != null ||
            !(_form.currentState?.validate() ?? false) ||
            _country == null ||
            _region == null))
      return;
    _update(() {
      _busy = true;
      _notice = null;
    });
    try {
      TimewebInitialProfileOutcome outcome;
      if (pending) {
        outcome = await flow.check().timeout(flow.observationTimeout);
      } else {
        final snapshot = await widget.runtime.readCurrentOwnProfile();
        if (!_current) return;
        snapshot.requireCurrent();
        final profile = snapshot.profile;
        if (profile == null ||
            profile.profileDetailsSaved != false ||
            profile.isRegistrationEnd != false ||
            snapshot.onboarding == TimewebOnboarding.search)
          throw StateError('Profile changed.');
        final request = TimewebInitialProfileRequest(
          expectedUpdatedAt: profile.updatedAt,
          changes: TimewebProfileChanges(
            fullName: _fields['fullName']!.text,
            age: int.tryParse(_fields['age']!.text.trim()),
            rost: int.tryParse(_fields['rost']!.text.trim()),
            about: _fields['about']!.text,
            hobbi: _fields['hobbi']!.text,
            deti: _children,
            pol: _gender,
            relationStatus: _relation,
          ),
          geography: await TimewebGeographyChanges.fromCatalog(countryCode: _country!, region: _region!),
          photos: flow.readyPhotos,
        );
        if (!_current) return;
        outcome = await flow.submit(request).timeout(flow.observationTimeout);
      }
      if (!_current) return;
      if (outcome == TimewebInitialProfileOutcome.confirmed) {
        flow.receipt!.requireCurrent();
        Navigator.of(context).pop(true);
      } else if (outcome == TimewebInitialProfileOutcome.rejected) {
        _notice = 'Сервис пока недоступен. Попробуйте позднее.';
      } else {
        _unknown();
      }
    } catch (_) {
      if (_current) _unknown();
    } finally {
      if (mounted) _update(() => _busy = false);
    }
  }

  String? _validate(String field, String? value) {
    final text = (value ?? '').trim();
    if (field == 'age' || field == 'rost') {
      final number = int.tryParse(text), min = field == 'age' ? 18 : 1, max = field == 'age' ? 100 : 300;
      return number == null || number < min || number > max
          ? context.tr(field == 'age' ? 'Возраст должен быть от 18 до 100 лет' : 'Укажите корректный рост.')
          : null;
    }
    return text.runes.length < (field == 'fullName' ? 1 : 20)
        ? context.tr(field == 'fullName' ? 'Имя не может быть пустым' : 'Минимум 20 символов')
        : null;
  }

  Widget _text(String field, String label, {int? maximum, bool multiline = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey('timeweb-initial-$field'),
      controller: _fields[field],
      enabled: !_busy && _flow?.needsCheck != true,
      maxLength: maximum,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? null : 1,
      keyboardType: field == 'age' || field == 'rost' ? TextInputType.number : TextInputType.multiline,
      decoration: InputDecoration(labelText: context.tr(label)),
      validator: (value) => _validate(field, value),
    ),
  );

  Widget _select<T>(String field, String label, T? value, Map<T, String> values, void Function(T?) change) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<T>(
      key: ValueKey('timeweb-initial-$field'),
      value: values.containsKey(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: context.tr(label)),
      items: values.entries
          .map(
            (entry) => DropdownMenuItem(
              value: entry.key,
              child: Text(context.tr(entry.value), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      validator: (value) => value == null ? context.tr('Не указано') : null,
      onChanged: _busy || _flow?.needsCheck == true
          ? null
          : (value) {
              if (_current) _update(() => change(value));
            },
    ),
  );

  Widget _body() {
    if (!_current) return Center(child: Text(context.tr('Сеанс завершён')));
    final flow = _flow, country = GeoCatalog.byCode(_countries, _country);
    final count = flow?.readyPhotos.length ?? 0, pending = flow?.needsCheck == true;
    final photoPending = _upload?.metadata != null;
    final canFinish = flow != null && count == 3 && flow.photosVerified && !photoPending;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ClrsPanel(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.tr('Регистрация'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (!pending) ...[
                _text('fullName', 'Имя', maximum: 1000),
                Row(
                  children: [
                    Expanded(child: _text('age', 'Возраст', maximum: 3)),
                    const SizedBox(width: 8),
                    Expanded(child: _text('rost', 'Рост', maximum: 3)),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _select('country', 'Страна', country?.code, {for (final c in _countries) c.code: c.name}, (
                        value,
                      ) {
                        _country = value;
                        _region = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _select(
                        'region',
                        country?.regionLabel ?? 'Регион',
                        country?.regions.contains(_region) == true ? _region : null,
                        {for (final r in country?.regions ?? <String>[]) r: r},
                        (value) => _region = value,
                      ),
                    ),
                  ],
                ),
                _select('deti', 'Есть дети?', _children, const {
                  true: 'Да',
                  false: 'Нет',
                }, (value) => _children = value),
                _select('pol', 'Пол', _gender, {
                  'м': 'Мужской',
                  'ж': 'Женский',
                  if (_gender != null && _gender != 'м' && _gender != 'ж') _gender!: _gender!,
                }, (value) => _gender = value),
                _select('relationStatus', 'Статус', _relation, {
                  'свободен': 'Свободен',
                  'занят': 'Занят',
                  if (_relation != null && _relation != 'свободен' && _relation != 'занят') _relation!: _relation!,
                }, (value) => _relation = value),
                _text('hobbi', 'Интересы и увлечения', maximum: 4096, multiline: true),
                _text('about', 'О себе', maximum: 4096, multiline: true),
                Text('${context.tr('Фото')}: $count/3'),
                const SizedBox(height: 8),
                if (!pending && count < 3)
                  ElevatedButton.icon(
                    key: const ValueKey('timeweb-initial-add-photo'),
                    onPressed: _busy || _upload == null || _upload!.needsCheck ? null : _addPhoto,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(context.tr('Добавить фото')),
                  ),
                if (!pending && (photoPending || count > 0 && flow?.photosVerified != true))
                  TextButton(
                    key: const ValueKey('timeweb-initial-check-photo'),
                    onPressed: _busy ? null : _checkPhoto,
                    child: Text(context.tr('Проверить результат')),
                  ),
              ],
              if (pending) Text(context.tr('Результат пока не подтверждён. Нажмите «Проверить результат».')),
              if (_notice != null)
                Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(context.tr(_notice!))),
              if (_busy) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              ElevatedButton(
                key: const ValueKey('timeweb-initial-finish'),
                onPressed: _busy || flow == null || !pending && !canFinish ? null : _submit,
                child: Text(context.tr(pending ? 'Проверить результат' : 'Сохранить')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/family_main.jpg',
    appBar: AppBar(backgroundColor: Colors.transparent, title: const ClrsLogo(size: 34)),
    body: SafeArea(
      child: Navigator(
        key: _menus,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => ValueListenableBuilder<int>(valueListenable: _render, builder: (_, __, ___) => _body()),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _flow?.close();
    unawaited(_upload?.close() ?? Future<void>.value());
    unawaited(_subscription?.cancel());
    for (final controller in _fields.values) {
      controller.clear();
      controller.dispose();
    }
    _render.dispose();
    super.dispose();
  }
}
