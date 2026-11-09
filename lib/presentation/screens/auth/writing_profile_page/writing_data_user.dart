import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/service/profile_draft_store.dart';
import 'package:wbrs/service/profile_registration_service.dart';
import 'package:wbrs/service/profile_photo_upload.dart';
import 'package:wbrs/presentation/screens/auth/session_gate.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/language_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/service/auth_service.dart';

class AboutUserWriting extends StatefulWidget {
  const AboutUserWriting({super.key, this.registration, this.onSaved});
  final ProfileRegistrationService? registration;
  final VoidCallback? onSaved;

  @override
  State<AboutUserWriting> createState() => _AboutUserWritingState();
}

class _AboutUserWritingState extends State<AboutUserWriting> {
  final _age = TextEditingController();
  final _height = TextEditingController();
  final _interests = TextEditingController();
  final _about = TextEditingController();
  final _picker = ImagePicker();

  List<GeoCountry> _countries = const [];
  String? _countryCode;
  String? _region;
  String? _children;
  String? _gender;
  String? _relationStatus;
  bool _is18 = false;
  bool _loadingGeo = true;
  bool _saving = false;
  bool _returning = false;
  int _mainPhotoIndex = 0;
  final List<XFile> _photos = [];
  final List<ProfileDraftPhoto> _draftPhotos = [];
  late final ProfileRegistrationService _registration;
  ProfileDraft? _draft;
  ProfileRegistrationRequest? _request;
  bool _restoring = true;
  String? _draftNotice;
  int _revision = 0;
  bool get _locked => _request != null || _restoring;

  GeoCountry? get _country => GeoCatalog.byCode(_countries, _countryCode);

  @override
  void initState() {
    super.initState();
    _registration = widget.registration ?? ProfileRegistrationService();
    for (final controller in [_age, _height, _interests, _about]) {
      controller.addListener(_persistDraft);
    }
    _restoreDraft();
  }

  Future<void> _restoreDraft() async {
    try {
      if (!_registration.isCurrentSession) {
        throw StateError('Сеанс завершён. Войдите снова.');
      }
      final uid = _registration.ownerUid!;
      final countries = await GeoCatalog.load();
      var draft = await _registration.store.load(uid);
      _request = _registration.pending;
      if (_request?.write.failed == true) _request = null;
      draft ??= _request?.draft ??
          ProfileDraft(uid: uid, fields: {
            'fullName': await _registration.initialName(),
            'countryCode': 'RU',
          });
      final files = <XFile>[];
      for (final photo in draft.photos) {
        files
            .add(XFile((await _registration.store.photoFile(uid, photo)).path));
      }
      if (!mounted || !_registration.isCurrentSession) return;
      setState(() {
        _countries = countries;
        _draft = draft;
        _countryCode = draft!.fields['countryCode']?.toString();
        _region = _country?.regions.contains(draft.fields['region']) == true
            ? draft.fields['region']?.toString()
            : null;
        _children = draft.fields['children']?.toString();
        _gender = draft.fields['gender']?.toString();
        _relationStatus = draft.fields['relationStatus']?.toString();
        _is18 = draft.fields['is18'] == true;
        _age.text = draft.fields['age']?.toString() ?? '';
        _height.text = draft.fields['height']?.toString() ?? '';
        _interests.text = draft.fields['interests']?.toString() ?? '';
        _about.text = draft.fields['about']?.toString() ?? '';
        _photos.addAll(files);
        _draftPhotos.addAll(draft.photos);
        final main =
            draft.photos.indexWhere((photo) => photo.id == draft!.mainPhotoId);
        _mainPhotoIndex = main < 0 ? 0 : main;
        _loadingGeo = false;
        _restoring = false;
        _draftNotice = files.isNotEmpty || _age.text.isNotEmpty
            ? 'Черновик анкеты восстановлен на этом устройстве.'
            : null;
      });
      if (_request == null && draft.commitStarted) {
        _request = _registration.start(draft);
      }
      if (_request != null && mounted) {
        setState(() => _draftNotice =
            'Сохранение анкеты ожидает подтверждения. Проверьте результат.');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _restoring = false;
          _loadingGeo = false;
          _draftNotice =
              'Не удалось восстановить черновик. Повторите загрузку.';
        });
      }
    }
  }

  ProfileDraft _snapshotDraft() => _draft!.copyWith(
          fields: {
            ..._draft!.fields,
            'countryCode': _countryCode,
            'region': _region,
            'children': _children,
            'gender': _gender,
            'relationStatus': _relationStatus,
            'is18': _is18,
            'age': _age.text,
            'height': _height.text,
            'interests': _interests.text,
            'about': _about.text,
          },
          photos: _draftPhotos,
          mainPhotoId:
              _draftPhotos.isEmpty ? null : _draftPhotos[_mainPhotoIndex].id);

  Future<void> _persistDraft() async {
    if (_restoring ||
        _saving ||
        _draft == null ||
        _locked ||
        !_registration.isCurrentSession) {
      return;
    }
    final revision = ++_revision;
    final draft = _snapshotDraft();
    _draft = draft;
    try {
      await _registration.store.save(draft);
      if (mounted && revision == _revision && !_locked) {
        setState(() => _draftNotice = 'Черновик сохранён на этом устройстве.');
      }
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _draftNotice =
            'Не удалось сохранить черновик на устройстве. Проверьте свободное место.');
      }
    }
  }

  void _change(VoidCallback change) {
    if (_locked || _saving) return;
    setState(change);
    _persistDraft();
  }

  @override
  void dispose() {
    _age.dispose();
    _height.dispose();
    _interests.dispose();
    _about.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _returnToLogin();
        },
        child: ClrsScaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: LrsTheme.text,
            toolbarHeight: largeText ? 92 : 60,
            leading: IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: _returnToLogin,
                icon: const Icon(Icons.arrow_back)),
            title: Text(context.tr('Расскажите о себе'),
                maxLines: 3,
                style: const TextStyle(
                    fontSize: 20, fontFamily: 'CormorantGaramond')),
            actions: const [LanguagePickerButton(compact: true)],
          ),
          body: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          context.tr(
                              'Это поможет найти людей, которые разделяют ваши ценности и цели.'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: LrsTheme.text,
                              fontSize: 12,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 5)
                              ])),
                      const SizedBox(height: 14),
                      _photoSection(),
                      const SizedBox(height: 12),
                      _fieldCard(
                          label: 'Страна',
                          icon: Icons.public,
                          child: _loadingGeo
                              ? const LinearProgressIndicator()
                              : _dropdown(
                                  value: _countryCode,
                                  values: {
                                    for (final country in _countries)
                                      country.code: country.name
                                  },
                                  translateValues: true,
                                  onChanged: (value) => _change(() {
                                        _countryCode = value;
                                        _region = null;
                                      }))),
                      const SizedBox(height: 8),
                      _fieldCard(
                          label: _country?.regionLabel ?? 'Регион',
                          icon: Icons.map_outlined,
                          child: _dropdown(
                              value: _region,
                              values: {
                                for (final region
                                    in _country?.regions ?? <String>[])
                                  region: region
                              },
                              translateValues: true,
                              onChanged: _country == null
                                  ? null
                                  : (value) => _change(() => _region = value))),
                      const SizedBox(height: 8),
                      LayoutBuilder(builder: (context, constraints) {
                        final age = _fieldCard(
                            label: 'Возраст',
                            icon: Icons.calendar_month_outlined,
                            child: _numberField(_age, '25', 'profile-age'));
                        final height = _fieldCard(
                            label: 'Рост',
                            icon: Icons.height,
                            child:
                                _numberField(_height, '175', 'profile-height'));
                        if (largeText || constraints.maxWidth < 310) {
                          return Column(children: [
                            age,
                            const SizedBox(height: 8),
                            height
                          ]);
                        }
                        return Row(children: [
                          Expanded(child: age),
                          const SizedBox(width: 8),
                          Expanded(child: height)
                        ]);
                      }),
                      const SizedBox(height: 8),
                      _fieldCard(
                          label: 'Есть дети?',
                          icon: Icons.family_restroom,
                          child: _dropdown(
                              value: _children,
                              values: const {'да': 'Да', 'нет': 'Нет'},
                              translateValues: true,
                              onChanged: (value) =>
                                  _change(() => _children = value))),
                      const SizedBox(height: 8),
                      _fieldCard(
                          label: 'Пол',
                          icon: Icons.person_outline,
                          child: _dropdown(
                              value: _gender,
                              values: const {'м': 'Мужской', 'ж': 'Женский'},
                              translateValues: true,
                              onChanged: (value) =>
                                  _change(() => _gender = value))),
                      const SizedBox(height: 8),
                      _fieldCard(
                          label: 'Статус',
                          icon: Icons.favorite_outline,
                          child: _dropdown(
                              value: _relationStatus,
                              values: const {
                                'свободен': 'Свободен',
                                'занят': 'Занят'
                              },
                              translateValues: true,
                              onChanged: (value) =>
                                  _change(() => _relationStatus = value))),
                      const SizedBox(height: 8),
                      _textArea(
                          title: 'Интересы и увлечения',
                          controller: _interests,
                          minLength: 20,
                          hint: 'Путешествия, книги, семья, спорт...',
                          maxLines: 3),
                      const SizedBox(height: 8),
                      _textArea(
                          title: 'О себе',
                          controller: _about,
                          minLength: 20,
                          hint:
                              'Расскажите о себе, ценностях и целях знакомства',
                          maxLines: 4),
                      const SizedBox(height: 10),
                      ClrsPanel(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          child: CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                  context
                                      .tr('Я подтверждаю, что мне есть 18 лет'),
                                  style: const TextStyle(
                                      color: LrsTheme.text, fontSize: 12)),
                              value: _is18,
                              activeColor: LrsTheme.peach,
                              checkColor: const Color(0xFF21130D),
                              onChanged: _locked || _saving
                                  ? null
                                  : (value) =>
                                      _change(() => _is18 = value ?? false))),
                      if (_draftNotice != null)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(context.tr(_draftNotice!),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: LrsTheme.peachLight, fontSize: 11))),
                      if (_draft == null && !_restoring)
                        TextButton(
                            onPressed: () {
                              setState(() => _restoring = true);
                              _restoreDraft();
                            },
                            child: Text(
                                context.tr('Повторить загрузку черновика'))),
                      const SizedBox(height: 10),
                      Align(
                          alignment: Alignment.center,
                          child: ElevatedButton(
                              key: const ValueKey('profile-save'),
                              onPressed: _saving || _restoring || _draft == null
                                  ? null
                                  : _validateAndSave,
                              child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                        child: Text(
                                            context.tr(_request != null
                                                ? 'Проверить сохранение анкеты'
                                                : 'Пройти тест'),
                                            textAlign: TextAlign.center)),
                                    const SizedBox(width: 10),
                                    _saving
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))
                                        : const Icon(Icons.arrow_forward,
                                            size: 18),
                                  ]))),
                      const SizedBox(height: 14),
                      const Row(children: [
                        Expanded(child: Divider(color: LrsTheme.peach)),
                        Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('✝',
                                style: TextStyle(
                                    color: LrsTheme.peach, fontSize: 26))),
                        Expanded(child: Divider(color: LrsTheme.peach))
                      ]),
                      const SizedBox(height: 8),
                      Text(
                          context.tr(
                              'Чем честнее вы ответите, тем точнее мы подберём для вас подходящих людей.'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: LrsTheme.text,
                              fontSize: 11,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 5)
                              ])),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
  }

  Future<void> _returnToLogin() async {
    if (_returning) return;
    if (_saving) {
      showSnackbar(
          context,
          LrsTheme.surface,
          context.tr(
              'Сохранение анкеты ожидает подтверждения. Проверьте результат.'));
      return;
    }
    setState(() => _returning = true);
    try {
      await _persistDraft();
      if (!mounted) return;
      final email = firebaseAuth.currentUser?.email ?? '';
      await AuthService().signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => LoginPage(initialEmail: email)),
        (_) => false,
      );
    } catch (_) {
      if (mounted) {
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось выйти. Попробуйте ещё раз.'));
      }
    } finally {
      if (mounted) setState(() => _returning = false);
    }
  }

  Widget _photoSection() {
    return LayoutBuilder(builder: (context, constraints) {
      const photoLabelStyle = TextStyle(
          inherit: false,
          fontFamily: 'Lato',
          fontSize: 11,
          fontWeight: FontWeight.w400,
          height: 1.3,
          color: LrsTheme.text);
      double labelHeight(String text, double width) {
        final painter = TextPainter(
            text: TextSpan(text: context.tr(text), style: photoLabelStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context))
          ..layout(maxWidth: width);
        final height = painter.height;
        painter.dispose();
        return height;
      }

      final mainWidth = (constraints.maxWidth * .25).clamp(72.0, 96.0);
      final slotWidth =
          ((constraints.maxWidth - mainWidth - 24) / 3).clamp(50.0, 94.0);
      final addHeight = labelHeight('Добавить фото', slotWidth - 16) + 54;
      final mainHeight =
          labelHeight('Главное фото', mainWidth) + mainWidth + 10;
      final height = addHeight > mainHeight ? addHeight : mainHeight;
      final secondary = [
        for (var i = 0; i < _photos.length; i++)
          if (i != _mainPhotoIndex) i
      ];
      final slots = secondary.length < 3
          ? 3
          : secondary.length + (_photos.length < 10 ? 1 : 0);
      Widget photoImage(int index) => Image.file(File(_photos[index].path),
          cacheWidth: 320,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.broken_image_outlined));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
            height: height,
            child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: slots + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, slot) {
                  if (slot == 0) {
                    return SizedBox(
                        width: mainWidth,
                        child: Column(children: [
                          SizedBox(
                              width: mainWidth,
                              height: mainWidth,
                              child: Stack(children: [
                                Positioned.fill(
                                    child: Material(
                                        shape: const CircleBorder(
                                            side: BorderSide(
                                                color: LrsTheme.peachLight,
                                                width: 2)),
                                        clipBehavior: Clip.antiAlias,
                                        color: const Color(0x5531241D),
                                        child: InkWell(
                                            onTap: _locked || _saving
                                                ? null
                                                : () =>
                                                    _pickPhotos(makeMain: true),
                                            child: _photos.isEmpty
                                                ? const Icon(
                                                    Icons.person_outline,
                                                    color: LrsTheme.peachLight,
                                                    size: 36)
                                                : photoImage(
                                                    _mainPhotoIndex)))),
                                if (_photos.isNotEmpty)
                                  Positioned(
                                      top: 0,
                                      right: 0,
                                      child: IconButton(
                                          tooltip: context.tr('Удалить фото'),
                                          onPressed: _locked || _saving
                                              ? null
                                              : () =>
                                                  _removePhoto(_mainPhotoIndex),
                                          style: IconButton.styleFrom(
                                              backgroundColor: Colors.black54,
                                              foregroundColor: Colors.white),
                                          icon: const Icon(Icons.close,
                                              size: 16))),
                                const Positioned(
                                    right: 2,
                                    bottom: 2,
                                    child: IgnorePointer(
                                        child: CircleAvatar(
                                            radius: 16,
                                            backgroundColor: LrsTheme.peach,
                                            child: Icon(
                                                Icons.camera_alt_outlined,
                                                color: LrsTheme.surface,
                                                size: 20)))),
                              ])),
                          const SizedBox(height: 6),
                          Text(context.tr('Главное фото'),
                              textAlign: TextAlign.center,
                              style: photoLabelStyle),
                        ]));
                  }
                  final position = slot - 1;
                  if (position >= secondary.length) {
                    return SizedBox(
                        width: slotWidth,
                        child: OutlinedButton(
                            onPressed:
                                _locked || _saving || _photos.length >= 10
                                    ? null
                                    : _pickPhotos,
                            style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.all(8),
                                backgroundColor: const Color(0x5531241D),
                                side:
                                    const BorderSide(color: Color(0x99E7B092)),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14))),
                            child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.add,
                                      color: LrsTheme.peach, size: 24),
                                  const SizedBox(height: 6),
                                  Text(context.tr('Добавить фото'),
                                      textAlign: TextAlign.center,
                                      style: photoLabelStyle),
                                ])));
                  }
                  final index = secondary[position];
                  return Semantics(
                      button: true,
                      label: context.tr('Фотография {number}',
                          args: {'number': index + 1}),
                      child: SizedBox(
                          width: slotWidth,
                          child: Stack(fit: StackFit.expand, children: [
                            Material(
                                color: Colors.transparent,
                                shape: RoundedRectangleBorder(
                                    side:
                                        const BorderSide(color: Colors.white38),
                                    borderRadius: BorderRadius.circular(14)),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                    onTap: _locked || _saving
                                        ? null
                                        : () => _change(
                                            () => _mainPhotoIndex = index),
                                    child: photoImage(index))),
                            Positioned(
                                top: 0,
                                right: 0,
                                child: IconButton(
                                    tooltip: context.tr('Удалить фото'),
                                    onPressed: _locked || _saving
                                        ? null
                                        : () => _removePhoto(index),
                                    style: IconButton.styleFrom(
                                        backgroundColor: Colors.black54,
                                        foregroundColor: Colors.white),
                                    iconSize: 16,
                                    icon: const Icon(Icons.close))),
                          ])));
                })),
        const SizedBox(height: 7),
        Text(
            context.tr(
                'Не менее 3 фото. Нажмите на фото, чтобы сделать его главным.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: LrsTheme.text, fontSize: 11)),
        if (_gender == 'м') ...[
          const SizedBox(height: 5),
          Text(
              context.tr(
                  'Рекомендация: мужчинам лучше поставить главным фото в костюме, форме или классической рубашке.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: LrsTheme.peachLight, fontSize: 22)),
        ],
      ]);
    });
  }

  Widget _fieldCard(
      {required String label, required IconData icon, required Widget child}) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    return ClrsPanel(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: LayoutBuilder(builder: (context, constraints) {
          final heading = Row(children: [
            Icon(icon, color: LrsTheme.peachLight, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(context.tr(label),
                    style:
                        const TextStyle(color: LrsTheme.text, fontSize: 12))),
          ]);
          if (largeText || constraints.maxWidth < 155) {
            return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [heading, child]);
          }
          return Row(children: [
            Expanded(flex: 4, child: heading),
            const SizedBox(width: 6),
            Expanded(flex: 5, child: child)
          ]);
        }));
  }

  Widget _numberField(
          TextEditingController controller, String hint, String key) =>
      TextField(
          key: ValueKey(key),
          controller: controller,
          readOnly: _locked || _saving,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          style: const TextStyle(color: LrsTheme.text, fontSize: 13),
          decoration: InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              hintText: hint,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              isDense: true));

  Widget _dropdown(
          {required String? value,
          required Map<String, String> values,
          required ValueChanged<String?>? onChanged,
          bool translateValues = false}) =>
      DropdownButtonHideUnderline(
          child: DropdownButton<String>(
        value: values.containsKey(value) ? value : null,
        dropdownColor: LrsTheme.surface,
        isExpanded: true,
        itemHeight: null,
        alignment: Alignment.centerRight,
        style: const TextStyle(color: LrsTheme.text, fontSize: 13),
        hint: Text(context.tr('Выбрать'),
            style: const TextStyle(color: LrsTheme.muted, fontSize: 12)),
        items: values.entries
            .map((item) => DropdownMenuItem<String>(
                value: item.key,
                child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(translateValues
                        ? context.tr(item.value)
                        : item.value))))
            .toList(),
        onChanged: _locked || _saving ? null : onChanged,
      ));

  Widget _textArea(
          {required String title,
          required TextEditingController controller,
          required int minLength,
          required String hint,
          required int maxLines}) =>
      ClrsPanel(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(context.tr(title),
                style: const TextStyle(color: LrsTheme.text, fontSize: 12)),
            TextField(
                controller: controller,
                readOnly: _locked || _saving,
                minLines: 2,
                maxLines: maxLines,
                style: const TextStyle(color: LrsTheme.text, fontSize: 13),
                decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    hintText: context.tr(hint),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8))),
            ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (_, value, __) => Text(
                    context.tr('{current} / минимум {minimum} символов', args: {
                      'current': context.l10n.number(value.text.trim().length),
                      'minimum': context.l10n.number(minLength)
                    }),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 10,
                        color: value.text.trim().length >= minLength
                            ? LrsTheme.peachLight
                            : LrsTheme.muted))),
          ]));

  Future<void> _pickPhotos({bool makeMain = false}) async {
    if (_locked || _saving || _draft == null) return;
    try {
      final pickerTimer = Stopwatch()..start();
      final selected = await _picker.pickMultiImage(
          imageQuality: 80, maxWidth: 1800, maxHeight: 1800);
      profilePhotoMetric('picker_return', pickerTimer.elapsed,
          count: selected.length);
      if (!mounted || !_registration.isCurrentSession || _locked) return;
      for (final image in selected.take(10 - _photos.length)) {
        final photo = await _registration.store
            .importPhoto(_registration.ownerUid!, image.path);
        final file =
            await _registration.store.photoFile(_registration.ownerUid!, photo);
        if (!mounted || !_registration.isCurrentSession || _locked) return;
        setState(() {
          _photos.add(XFile(file.path));
          _draftPhotos.add(photo);
          if (makeMain) _mainPhotoIndex = _photos.length - 1;
          makeMain = false;
        });
        await _persistDraft();
      }
    } catch (_) {
      if (mounted) {
        showSnackbar(
            context,
            LrsTheme.danger,
            context.tr(
                'Не удалось сохранить выбранную фотографию. Повторите попытку.'));
      }
    }
  }

  void _removePhoto(int index) {
    if (_saving || _locked) return;
    _change(() {
      _photos.removeAt(index);
      _draftPhotos.removeAt(index);
      if (_photos.isEmpty || _mainPhotoIndex == index) {
        _mainPhotoIndex = 0;
      } else if (_mainPhotoIndex > index) {
        _mainPhotoIndex--;
      }
    });
  }

  Future<void> _validateAndSave() async {
    if (_saving || _restoring || _draft == null) return;
    if (_request != null) {
      await _waitForSave();
      return;
    }
    final ageValue = int.tryParse(_age.text.trim());
    final heightValue = int.tryParse(_height.text.trim());

    String? error;
    if (_photos.length < 3) {
      error = 'Добавьте минимум 3 фотографии.';
    } else if (_country == null) {
      error = 'Выберите страну.';
    } else if (_region == null || _region!.trim().isEmpty) {
      error = 'Выберите регион.';
    } else if (ageValue == null || ageValue < 18 || ageValue > 100) {
      error = 'Укажите корректный возраст от 18 до 100 лет.';
    } else if (heightValue == null || heightValue < 100 || heightValue > 230) {
      error = 'Укажите корректный рост.';
    } else if (_children == null) {
      error = 'Укажите, есть ли у вас дети.';
    } else if (_gender == null) {
      error = 'Укажите пол.';
    } else if (_relationStatus == null) {
      error = 'Статус не указан';
    } else if (_interests.text.trim().length < 20) {
      error = 'Интересы и увлечения — минимум 20 символов.';
    } else if (_about.text.trim().length < 20) {
      error = '${context.tr('О себе')}: ${context.tr('Минимум 20 символов')}';
    } else if (!_is18) {
      error = 'Подтвердите, что вам есть 18 лет.';
    }

    if (error != null) {
      showSnackbar(context, LrsTheme.danger, context.tr(error));
      return;
    }

    final frozen = _snapshotDraft();
    setState(() => _saving = true);
    try {
      await _registration.store.save(frozen);
      if (!mounted || !_registration.isCurrentSession) return;
      _request = _registration.start(frozen);
      await _waitForSave(alreadySaving: true);
    } catch (_) {
      if (mounted) {
        showSnackbar(
            context,
            LrsTheme.danger,
            context
                .tr('Не удалось начать сохранение анкеты. Повторите попытку.'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _waitForSave({bool alreadySaving = false}) async {
    if ((_saving && !alreadySaving) || _request == null) return;
    setState(() => _saving = true);
    try {
      final confirmed = await _request!.write.wait();
      if (!mounted) return;
      if (!_registration.isCurrentSession) {
        setState(() => _draftNotice =
            'Сеанс изменился. Войдите в исходный аккаунт, чтобы продолжить.');
        return;
      }
      if (!confirmed) {
        setState(() => _draftNotice =
            'Сохранение ещё выполняется. Повторная проверка ждёт эту же операцию; фотографии не загружаются заново.');
        return;
      }
      await _registration.acknowledge(_request!);
      if (!mounted || !_registration.isCurrentSession) return;
      showSnackbar(context, LrsTheme.surface, context.tr('Анкета сохранена'));
      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
        nextScreenReplace(context, const SessionGate());
      }
    } catch (_) {
      final recovered = await _registration.store
          .load(_registration.ownerUid!)
          .catchError((_) => null);
      if (!mounted) return;
      setState(() {
        _request = null;
        if (recovered != null) {
          _draft = recovered;
          _draftPhotos
            ..clear()
            ..addAll(recovered.photos);
        }
        _draftNotice =
            'Не удалось подтвердить сохранение анкеты. Черновик сохранён; проверьте соединение и повторите попытку.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
