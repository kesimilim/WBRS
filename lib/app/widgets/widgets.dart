import 'package:flutter/material.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

const textInputDecoration = InputDecoration(
  filled: true,
  fillColor: LrsTheme.surfaceSoft,
  labelStyle: TextStyle(color: LrsTheme.muted, fontWeight: FontWeight.w400),
  hintStyle: TextStyle(color: LrsTheme.muted),
  contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(18)),
    borderSide: BorderSide(color: LrsTheme.peach, width: 1.4),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(18)),
    borderSide: BorderSide(color: Color(0x55E7B092), width: 1),
  ),
  errorBorder: OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(18)),
    borderSide: BorderSide(color: LrsTheme.danger, width: 1.2),
  ),
  focusedErrorBorder: OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(18)),
    borderSide: BorderSide(color: LrsTheme.danger, width: 1.2),
  ),
  disabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(18)),
    borderSide: BorderSide(color: Color(0x33E7B092), width: 1),
  ),
);

Future nextScreen(context, page) {
  return Navigator.push(context, MaterialPageRoute(builder: (context) => page));
}

Future nextScreenReplace(context, page) {
  return Navigator.pushReplacement(
      context, MaterialPageRoute(builder: (context) => page));
}

void showSnackbar(BuildContext context, Color color, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: const TextStyle(fontSize: 14, color: Colors.white),
      ),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
      action: SnackBarAction(
        label: context.tr('ОК'),
        onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        textColor: Colors.white,
      ),
    ),
  );
}
