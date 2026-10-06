import 'package:flutter/material.dart';
import 'clrs_localizations.dart';
import 'locale_controller.dart';

/// Compact language entry point used by login, registration and settings.
class LanguagePickerButton extends StatelessWidget {
  const LanguagePickerButton({
    super.key,
    this.controller,
    this.compact = false,
    this.showIcon = true,
  });
  final LocaleController? controller;
  final bool compact;
  final bool showIcon;
  @override
  Widget build(BuildContext context) {
    final selected = controller ?? LocaleController.instance;
    return AnimatedBuilder(
      animation: selected,
      builder: (context, _) {
        final label =
            ClrsLocalizations.nativeNames[selected.locale.languageCode] ??
            'Русский';
        void open() => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => _LanguageSheet(controller: selected),
        );
        if (compact) {
          return IconButton(
            tooltip: context.tr('Язык'),
            onPressed: open,
            icon: const Icon(Icons.language),
          );
        }
        if (!showIcon) {
          return TextButton(
            onPressed: open,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              textStyle: const TextStyle(fontFamily: 'Lato', fontSize: 12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
          );
        }
        return TextButton.icon(
          onPressed: open,
          icon: const Icon(Icons.language, size: 20),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
      },
    );
  }
}

class _LanguageSheet extends StatefulWidget {
  const _LanguageSheet({required this.controller});
  final LocaleController controller;
  @override
  State<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<_LanguageSheet> {
  bool _saving = false;
  String? _error;
  Future<void> _choose(String code) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.setLanguage(code);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = context.tr(
            'Не удалось сохранить язык. Попробуйте ещё раз.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: .8,
    child: SafeArea(
      top: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Язык'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Закрыть'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
          if (_saving)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            ),
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final code = ClrsLocalizations.codes[index];
              return ListTile(
                title: Text(ClrsLocalizations.nativeNames[code]!),
                trailing: widget.controller.locale.languageCode == code
                    ? const Icon(Icons.check)
                    : null,
                selected: widget.controller.locale.languageCode == code,
                onTap: _saving ? null : () => _choose(code),
              );
            }, childCount: ClrsLocalizations.codes.length),
          ),
        ],
      ),
    ),
  );
}
