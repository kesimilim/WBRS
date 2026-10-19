import 'dart:async';
import 'package:flutter/material.dart';

class ClrsBackgroundController extends ChangeNotifier {
  ClrsBackgroundController._();

  static final ClrsBackgroundController instance = ClrsBackgroundController._();
  static const List<String> defaultImages = [
    'assets/final_design/family_right.png',
    'assets/final_design/family_back.png',
    'assets/final_design/family_front.png',
    'assets/family_main.jpg',
    'assets/family_forms.jpg',
  ];

  int _currentIndex = 0;
  Timer? _timer;
  bool _precached = false;

  int get currentIndex => _currentIndex;
  String get currentImage => defaultImages[_currentIndex];

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (hasListeners && _timer == null) {
      _startTimer();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      stopTimer();
    }
  }

  void stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void startTimer() {
    if (_timer == null) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      _currentIndex = (_currentIndex + 1) % defaultImages.length;
      notifyListeners();
    });
  }

  void precache(BuildContext context) {
    if (_precached) return;
    _precached = true;
    for (final asset in defaultImages) {
      precacheImage(AssetImage(asset), context).ignore();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class ClrsAnimatedBackground extends StatefulWidget {
  const ClrsAnimatedBackground({
    super.key,
    this.backgroundAsset,
    this.scale = 1.0,
  });

  final String? backgroundAsset;
  final double scale;

  @override
  State<ClrsAnimatedBackground> createState() => _ClrsAnimatedBackgroundState();
}

class _ClrsAnimatedBackgroundState extends State<ClrsAnimatedBackground> {
  static const String _primaryBaseImage = 'assets/final_design/family_right.png';
  String? _previousImage;
  String? _currentImage;

  @override
  void initState() {
    super.initState();
    _currentImage = ClrsBackgroundController.instance.currentImage;
    ClrsBackgroundController.instance.addListener(_onBackgroundChanged);
  }

  @override
  void dispose() {
    ClrsBackgroundController.instance.removeListener(_onBackgroundChanged);
    super.dispose();
  }

  void _onBackgroundChanged() {
    final nextImage = ClrsBackgroundController.instance.currentImage;
    if (nextImage != _currentImage) {
      setState(() {
        _previousImage = _currentImage;
        _currentImage = nextImage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ClrsBackgroundController.instance.precache(context);

    if (widget.backgroundAsset != null &&
        widget.backgroundAsset != 'assets/final_design/family_right.png' &&
        widget.backgroundAsset != 'assets/final_design/family_back.png'
    ) {
      return Transform.scale(
        scale: widget.scale,
        alignment: Alignment.bottomCenter,
        child: Image.asset(
          widget.backgroundAsset!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
      );
    }

    final current = _currentImage ?? ClrsBackgroundController.instance.currentImage;
    final previous = _previousImage;

    return Container(
      color: const Color(0xFF20130B),
      child: Transform.scale(
        scale: widget.scale,
        alignment: Alignment.bottomCenter,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Primary main background image is always rendered at the base for instant first launch
            Image.asset(
              _primaryBaseImage,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
            if (previous != null && previous != _primaryBaseImage)
              Image.asset(
                previous,
                key: ValueKey<String>('prev_$previous'),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 2500),
              switchInCurve: Curves.easeInOut,
              switchOutCurve: Curves.easeInOut,
              layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: Image.asset(
                current,
                key: ValueKey<String>(current),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
