import 'clrs_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'lrs_theme.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

/// Live widgets over an unblurred photograph; never a screenshot used as UI.
class ClrsScaffold extends StatefulWidget {
  const ClrsScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.drawer,
    this.bottomNavigationBar,
    this.backgroundColor,
    this.backgroundAsset = 'assets/final_design/family_right.png',
    this.backgroundScale = 1,
    this.floatingActionButton,
    this.extendBodyBehindAppBar = false,
  });
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? drawer, bottomNavigationBar, floatingActionButton;
  final Color? backgroundColor;
  final String backgroundAsset;
  final double backgroundScale;
  final bool extendBodyBehindAppBar;
  @override
  State<ClrsScaffold> createState() => _ClrsScaffoldState();
}

class _ClrsScaffoldState extends State<ClrsScaffold> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _drawerOpen = false;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_drawerOpen,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _drawerOpen) _scaffoldKey.currentState?.closeDrawer();
    },
    child: Stack(
      children: [
        Positioned.fill(
          child: Transform.scale(
            scale: widget.backgroundScale,
            alignment: Alignment.bottomCenter,
            child: Image.asset(widget.backgroundAsset, fit: BoxFit.cover),
          ),
        ),
        Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: Theme.of(context).inputDecorationTheme
                .copyWith(
                  fillColor: const Color(0xB038281D),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: LrsTheme.actionGlass,
                foregroundColor: LrsTheme.text,
                disabledBackgroundColor: LrsTheme.actionDisabled,
                disabledForegroundColor: LrsTheme.muted,
                minimumSize: const Size(48, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                side: const BorderSide(color: LrsTheme.actionBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: LrsTheme.actionGlass,
                foregroundColor: LrsTheme.text,
                disabledBackgroundColor: LrsTheme.actionDisabled,
                disabledForegroundColor: LrsTheme.muted,
                side: const BorderSide(color: LrsTheme.actionBorder),
              ),
            ),
          ),
          child: Scaffold(
            key: _scaffoldKey,
            backgroundColor: Colors.transparent,
            extendBodyBehindAppBar: widget.extendBodyBehindAppBar,
            appBar: widget.appBar,
            drawer: widget.drawer,
            onDrawerChanged: (open) {
              if (_drawerOpen != open) setState(() => _drawerOpen = open);
            },
            bottomNavigationBar: widget.bottomNavigationBar,
            floatingActionButton: widget.floatingActionButton,
            body: widget.body,
          ),
        ),
      ],
    ),
  );
}

class ClrsPanel extends StatelessWidget {
  const ClrsPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: const Color(0xAD302110),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x66E7B092), width: .8),
    ),
    child: child,
  );
}

class ClrsBrandHeader extends StatelessWidget {
  const ClrsBrandHeader({super.key, this.centered = false});
  final bool centered;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
    child: Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [ClrsLogo(centered: centered)],
    ),
  );
}

class ClrsValuesFooter extends StatelessWidget {
  const ClrsValuesFooter({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: compact ? 8 : 20),
    child: Column(
      children: [
        Row(
          children: [
            const Expanded(child: Divider(color: LrsTheme.peach)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 14),
              child: ExcludeSemantics(
                child: CustomPaint(
                  size: compact ? const Size(16, 20) : const Size(20, 28),
                  painter: _CrossPainter(),
                ),
              ),
            ),
            const Expanded(child: Divider(color: LrsTheme.peach)),
          ],
        ),
        SizedBox(height: compact ? 6 : 10),
        Text(
          context.tr('Настоящие люди · Общие ценности\nРеальные отношения'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: LrsTheme.peachLight,
            fontSize: compact ? 9.5 : 11,
            height: compact ? 1.25 : 1.5,
          ),
        ),
        SizedBox(height: compact ? 6 : 12),
        Icon(
          Icons.favorite_border,
          color: LrsTheme.peach,
          size: compact ? 18 : null,
        ),
      ],
    ),
  );
}

class _CrossPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = LrsTheme.peach
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width / 2, 1),
      Offset(size.width / 2, size.height - 1),
      paint,
    );
    canvas.drawLine(
      Offset(1, size.height * .34),
      Offset(size.width - 1, size.height * .34),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CrossPainter oldDelegate) => false;
}

class ClrsDocumentPage extends StatefulWidget {
  const ClrsDocumentPage({super.key, required this.title, required this.asset});
  final String title, asset;
  @override
  State<ClrsDocumentPage> createState() => _ClrsDocumentPageState();
}

class _ClrsDocumentPageState extends State<ClrsDocumentPage> {
  late Future<String> _text;
  AssetBundle? _bundle;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = DefaultAssetBundle.of(context);
    if (_bundle != bundle) {
      _bundle = bundle;
      _text = _loadText();
    }
  }

  @override
  void didUpdateWidget(covariant ClrsDocumentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset != widget.asset) _text = _loadText();
  }

  // Do not retain a failed Future in CachingAssetBundle on an explicit retry.
  Future<String> _loadText() {
    final text = Future<String>.sync(
      () => _bundle!.loadString(widget.asset, cache: false),
    );
    // A retry can fail before the next frame subscribes in FutureBuilder.
    // Observe that early error while keeping the original future for the UI.
    text.ignore();
    return text;
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    appBar: AppBar(
      title: Text(context.tr(widget.title), maxLines: 2),
      toolbarHeight: 64 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
    ),
    body: FutureBuilder<String>(
      future: _text,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError)
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ClrsPanel(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.tr('Не удалось загрузить документ.')),
                    TextButton(
                      onPressed: () => setState(() {
                        _text = _loadText();
                      }),
                      child: Text(context.tr('Повторить')),
                    ),
                  ],
                ),
              ),
            ),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const ClrsBrandHeader(),
                ClrsPanel(
                  child: SelectableText(
                    snapshot.data!,
                    style: const TextStyle(
                      color: LrsTheme.text,
                      fontSize: 16,
                      height: 1.6,
                    ),
                  ),
                ),
                const ClrsValuesFooter(),
              ],
            ),
          ),
        );
      },
    ),
  );
}
