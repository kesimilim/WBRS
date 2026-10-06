import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/service/meeting_write_service.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/presentation/screens/list_of_meets/timeweb_meetings_page.dart';
import 'clrs_screen.dart';
import 'geo_catalog.dart';
import 'lrs_theme.dart';
import 'meeting_location_fields.dart';

String formatMeetingDateTime(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}.${two(date.month)}.${date.year} '
      '${two(date.hour)}:${two(date.minute)}';
}

DateTime? parseMeetingDateTime(String value) {
  final match = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4}) (\d{1,2}):(\d{2})$')
      .firstMatch(value);
  if (match == null) return null;
  final day = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final year = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final date = DateTime(year, month, day, hour, minute);
  return date.year == year &&
          date.month == month &&
          date.day == day &&
          date.hour == hour &&
          date.minute == minute
      ? date
      : null;
}

/// Shared form keeps create/edit behaviour and accessible sizing consistent.
class MeetingForm extends StatefulWidget {
  const MeetingForm(
      {super.key,
      this.meetingId,
      this.initialData = const {},
      this.service,
      this.nativeRuntime,
      this.onSaved});
  final String? meetingId;
  final Map<String, dynamic> initialData;
  final MeetingWriteService? service;
  final TimewebAppRuntime? nativeRuntime;
  final VoidCallback? onSaved;

  @override
  // The native State must be chosen before the legacy State initializes Firebase.
  // ignore: no_logic_in_create_state
  State<MeetingForm> createState() => nativeRuntime == null
      ? _MeetingFormState() : _NativeMeetingFormState();
}

// This branch is selected before the legacy State can construct Firebase services.
class _NativeMeetingFormState extends State<MeetingForm> {
  @override
  Widget build(BuildContext context) => widget.meetingId != null || widget.nativeRuntime == null
      ? ClrsScaffold(body: Center(child: Text(context.tr('Изменение встречи пока недоступно'))))
      : TimewebMeetingCreationView(runtime: widget.nativeRuntime!);
}

class _MeetingFormState extends State<MeetingForm> {
  late final MeetingWriteService _service;
  late final TextEditingController _name, _description;
  late final Map<String, dynamic> _initial;
  GeoCountry? _country;
  String? _region;
  String _type = 'групповая';
  String? _invitedUid;
  String? _invitedName;
  late String _dateText;
  late DateTime _selected;
  MeetingWrite? _operation;
  bool _busy = false;
  bool _restoring = true;
  bool _restoreFailed = false;
  String? _notice;
  bool get _creating => widget.meetingId == null;
  bool get _locked => _operation != null || _restoring || _restoreFailed;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? MeetingWriteService();
    _operation = _creating
        ? _service.pendingCreate
        : _service.pendingEdit(widget.meetingId!);
    if (_operation?.write.failed == true) _operation = null;
    _initial = {...widget.initialData, ...?_operation?.fields};
    _name = TextEditingController(text: _initial['name']?.toString() ?? '');
    _description =
        TextEditingController(text: _initial['description']?.toString() ?? '');
    _dateText = _initial['datetime']?.toString() ??
        formatMeetingDateTime(DateTime.now());
    _selected = parseMeetingDateTime(_dateText) ?? DateTime.now();
    _type = _initial['type']?.toString() ?? 'групповая';
    _invitedUid = _initial['invitedUid']?.toString();
    _invitedName = _initial['invitedName']?.toString();
    if (_operation != null) {
      _notice =
          'Предыдущая операция ожидает подтверждения. Проверьте результат.';
    }
    _restore();
  }

  Future<void> _restore() async {
    try {
      final request = await _service.restore(meetingId: widget.meetingId);
      if (!mounted) return;
      if (!_service.isCurrentSession) throw StateError('Сеанс изменился');
      setState(() {
        _operation = request;
        if (request != null) {
          _initial.addAll(request.fields);
          _name.text = _initial['name']?.toString() ?? '';
          _description.text = _initial['description']?.toString() ?? '';
          _dateText = _initial['datetime']?.toString() ?? _dateText;
          _selected = parseMeetingDateTime(_dateText) ?? _selected;
          _type = _initial['type']?.toString() ?? _type;
          _invitedUid = _initial['invitedUid']?.toString();
          _invitedName = _initial['invitedName']?.toString();
          _notice =
              'Предыдущая операция ожидает подтверждения. Проверьте результат.';
        }
        _restoring = false;
        _restoreFailed = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _restoring = false;
          _restoreFailed = true;
          _notice = 'Не удалось восстановить черновик. Повторите загрузку.';
        });
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final selected = DateUtils.dateOnly(_selected);
    final picked = await showDatePicker(
        context: context,
        initialDate: selected,
        firstDate: selected.isBefore(today) ? selected : today,
        lastDate: DateTime(_selected.year > 2100 ? _selected.year + 1 : 2101));
    if (!mounted || picked == null) return;
    setState(() {
      _selected = DateTime(picked.year, picked.month, picked.day,
          _selected.hour, _selected.minute);
      _dateText = formatMeetingDateTime(_selected);
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_selected),
        initialEntryMode: TimePickerEntryMode.input);
    if (!mounted || picked == null) return;
    setState(() {
      _selected = DateTime(_selected.year, _selected.month, _selected.day,
          picked.hour, picked.minute);
      _dateText = formatMeetingDateTime(_selected);
    });
  }

  Map<String, dynamic> get _fields => {
        'name': _name.text.trim(),
        'description': _description.text,
        'city': _region,
        'region': _region,
        'country': _country!.name,
        'countryCode': _country!.code,
        'datetime': _dateText,
        'type': _type,
        if (_type == 'индивидуальная' && _invitedUid != null)
          'invitedUid': _invitedUid,
        if (_type == 'индивидуальная' && _invitedName != null)
          'invitedName': _invitedName,
        if (_type == 'индивидуальная')
          'inviterName': firebaseAuth.currentUser?.displayName ?? '',
      };

  Future<void> _pickInvitee() async {
    final owner = firebaseAuth.currentUser?.uid;
    if (owner == null) return;
    final selected = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        var search = '';
        return StatefulBuilder(builder: (context, update) {
          final query = firebaseFirestore
              .collection('users')
              .orderBy('fullName')
              .startAt([search]).endAt(['$search\uf8ff']).limit(30);
          return SafeArea(
              child: Padding(
                  padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                      bottom: MediaQuery.viewInsetsOf(context).bottom + 16),
                  child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * .6,
                      child: Column(children: [
                        TextField(
                            autofocus: true,
                            onChanged: (value) =>
                                update(() => search = value.trim()),
                            decoration: InputDecoration(
                                labelText: context.tr('Поиск по имени'),
                                prefixIcon: const Icon(Icons.search))),
                        Expanded(
                            child: FutureBuilder<
                                    QuerySnapshot<Map<String, dynamic>>>(
                                future: query.get(),
                                builder: (context, snapshot) {
                                  if (snapshot.hasError) {
                                    return Center(
                                        child: Text(context.tr(
                                            'Не удалось загрузить пользователей')));
                                  }
                                  if (!snapshot.hasData) {
                                    return const Center(
                                        child: CircularProgressIndicator());
                                  }
                                  final people = snapshot.data!.docs
                                      .where((doc) =>
                                          doc.id != owner &&
                                          doc.data()['status'] != 'blocked' &&
                                          doc.data()['status'] != 'deleted')
                                      .toList();
                                  return ListView.builder(
                                      itemCount: people.length,
                                      itemBuilder: (context, index) {
                                        final person = people[index];
                                        final name =
                                            '${person.data()['fullName'] ?? ''}';
                                        return ListTile(
                                            title: Text(name),
                                            onTap: () => Navigator.pop(
                                                sheetContext,
                                                (person.id, name)));
                                      });
                                }))
                      ]))));
        });
      },
    );
    if (!mounted ||
        firebaseAuth.currentUser?.uid != owner ||
        selected == null) {
      return;
    }
    setState(() {
      _invitedUid = selected.$1;
      _invitedName = selected.$2;
    });
  }

  Future<void> _save() async {
    if (_busy || _restoring) return;
    if (_restoreFailed) {
      setState(() => _restoring = true);
      await _restore();
      return;
    }
    if (!_service.isCurrentSession) {
      setState(() => _notice = 'Сеанс завершён. Войдите снова.');
      return;
    }
    if (_operation == null &&
        (_name.text.trim().isEmpty || _country == null || _region == null)) {
      setState(() => _notice = 'Укажите название, страну и регион');
      return;
    }
    if (_operation == null &&
        _type == 'индивидуальная' &&
        (_invitedUid == null || _invitedUid!.isEmpty)) {
      setState(() => _notice = 'Выберите получателя');
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      _operation ??= _creating
          ? await _service.create(_fields)
          : await _service.edit(widget.meetingId!,
              '${widget.initialData['admin'] ?? ''}', _fields);
      final confirmed = await _operation!.write.wait();
      if (!mounted) return;
      if (!_service.isCurrentSession) {
        setState(() => _notice =
            'Сеанс изменился. Проверьте результат после входа в исходный аккаунт.');
        return;
      }
      if (!confirmed) {
        setState(() => _notice =
            'Подтверждение ещё не получено. Проверьте результат без повторной отправки.');
        return;
      }
      await _service.acknowledge(_operation!, creating: _creating);
      if (!mounted || !_service.isCurrentSession) return;
      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
        nextScreenReplace(context, const MeetingPage());
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _operation = null;
        _notice =
            'Не удалось сохранить изменения. Проверьте соединение и повторите попытку.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy || _locked) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                backgroundColor: LrsTheme.surfaceSoft,
                title: Text(context.tr('Удалить встречу?')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(context.tr('Отмена'))),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(context.tr('Удалить')))
                ]));
    if (!mounted || confirmed != true) return;
    try {
      setState(() => _busy = true);
      final operation = await _service.delete(
          widget.meetingId!, '${widget.initialData['admin'] ?? ''}');
      if (!mounted) return;
      setState(() {
        _operation = operation;
        _busy = false;
      });
      await _save();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _notice =
              'Не удалось удалить встречу. Проверьте сеанс и повторите попытку.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
        appBar: AppBar(
            title: Text(
                context.tr(_creating ? 'Создать встречу' : 'Изменить встречу'),
                maxLines: 2),
            toolbarHeight: 80),
        body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ClrsBrandHeader(),
                  AbsorbPointer(
                      absorbing: _locked || _busy,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                                controller: _name,
                                readOnly: _locked || _busy,
                                style:
                                    const TextStyle(color: LrsTheme.peachLight),
                                decoration: InputDecoration(
                                    labelText: context.tr('Название встречи'),
                                    border: OutlineInputBorder())),
                            const SizedBox(height: 14),
                            MeetingLocationFields(
                                key: ValueKey(
                                    '${_initial['countryCode']}/${_initial['region']}'),
                                countryCode:
                                    _initial['countryCode']?.toString(),
                                region: _initial['region']?.toString(),
                                onChanged: (country, region) {
                                  _country = country;
                                  _region = region;
                                }),
                            const SizedBox(height: 14),
                            TextField(
                                controller: _description,
                                readOnly: _locked || _busy,
                                maxLength: 300,
                                minLines: 2,
                                maxLines: null,
                                scrollPhysics:
                                    const NeverScrollableScrollPhysics(),
                                style:
                                    const TextStyle(color: LrsTheme.peachLight),
                                decoration: InputDecoration(
                                    labelText:
                                        context.tr('Краткое описание встречи'),
                                    border: OutlineInputBorder())),
                            Text(
                                '${context.tr('Дата и время')}: ${context.l10n.dateTime(_selected)}',
                                style: const TextStyle(
                                    color: LrsTheme.peachLight)),
                            const SizedBox(height: 8),
                            Wrap(spacing: 12, runSpacing: 8, children: [
                              ElevatedButton(
                                  onPressed:
                                      _locked || _busy ? null : _pickDate,
                                  child: Text(context.tr('Выбрать дату'))),
                              ElevatedButton(
                                  onPressed:
                                      _locked || _busy ? null : _pickTime,
                                  child: Text(context.tr('Выбрать время'))),
                            ]),
                            if (_creating)
                              Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: DropdownButtonFormField<String>(
                                      value: _type,
                                      isExpanded: true,
                                      decoration: InputDecoration(
                                          labelText: context.tr('Тип встречи')),
                                      items: [
                                        for (final type in const [
                                          'индивидуальная',
                                          'групповая'
                                        ])
                                          DropdownMenuItem(
                                              value: type,
                                              child: Text(context.tr(
                                                  type == 'индивидуальная'
                                                      ? 'Индивидуальная'
                                                      : 'Групповая')))
                                      ],
                                      onChanged: (value) {
                                        if (value != null) {
                                          setState(() => _type = value);
                                        }
                                      })),
                            if (_creating && _type == 'индивидуальная')
                              Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: OutlinedButton.icon(
                                      onPressed: _locked || _busy
                                          ? null
                                          : _pickInvitee,
                                      icon: const Icon(Icons.person_add_alt_1),
                                      label: Text(_invitedName == null
                                          ? context.tr('Выберите получателя')
                                          : '${context.tr('Получатель')}: $_invitedName'))),
                          ])),
                  if (_notice != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: ClrsPanel(
                            child: Text(context.tr(_notice!),
                                style: const TextStyle(
                                    color: LrsTheme.peachLight)))),
                  const SizedBox(height: 16),
                  if (_busy || _restoring)
                    const Center(child: CircularProgressIndicator()),
                  TextButton(
                      onPressed: _busy || _restoring ? null : _save,
                      child: Text(
                          context.tr(_restoreFailed
                              ? 'Повторить'
                              : _locked
                                  ? 'Проверить результат'
                                  : 'Сохранить'),
                          style: const TextStyle(
                              fontSize: 20, color: LrsTheme.peach))),
                  if (!_creating)
                    TextButton(
                        onPressed: _busy || _locked ? null : _delete,
                        child: Text(context.tr('Удалить'),
                            style: TextStyle(
                                color: Colors.redAccent, fontSize: 20))),
                ])),
      );
}
