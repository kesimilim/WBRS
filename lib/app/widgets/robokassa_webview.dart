import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:xml/xml.dart';

import '../helper/global.dart';
import 'package:http/http.dart' as http;

class RobokassaWebview extends StatefulWidget {
  final String sum;
  final int count;
  const RobokassaWebview({super.key, required this.sum, required this.count});

  @override
  State<RobokassaWebview> createState() => _RobokassaWebviewState();
}

class _RobokassaWebviewState extends State<RobokassaWebview>
    with WidgetsBindingObserver {
  static const bool isTestMode = bool.fromEnvironment('IS_TEST', defaultValue: false);
  static const String password1Prod = 'Grebat-kopat3102-';
  static const String password1Test = 'vcb3Ig7r50VnSXG7uXgV';
  static const String password2Prod = 'Zhevat-kopat3103-';
  static const String password2Test = 'IKgk1Lu6jz7V3ZvrJg6X';
  String get password1 => isTestMode ? password1Test : password1Prod;
  String get password2 => isTestMode ? password2Test : password2Prod;

  var ctrl = WebViewController();
  int _progress = 0;
  String sbpUrl = '', signature = '';
  Future addTransaction() async {
    await firebaseFirestore.collection('transaction').get().then((value) async {
      setState(() {
        firebaseFirestore
            .collection('transaction')
            .doc(widget.count.toString())
            .set({
          'id': widget.count.toString(),
          'sum': widget.sum,
          'user_email': firebaseAuth.currentUser!.email,
          'user_id': firebaseAuth.currentUser!.uid,
          'time': DateTime.now().toString(),
        });
      });
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);

    addTransaction();

    final outSum = double.parse(widget.sum).toStringAsFixed(2);
    signature = md5
        .convert(
            utf8.encode('WBRS:$outSum:${widget.count}:$password1'))
        .toString();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) async {
            debugPrint('WebView is loading (progress : $progress%)');
            setState(() {
              _progress = progress;
            });
          },
          onPageStarted: (String url) async {
            debugPrint('Page started loading: $url');
          },
          onPageFinished: (String url) {
            debugPrint('Page finished loading: $url');
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('''
              Page resource error:
              code: ${error.errorCode}
              description: ${error.description}
              errorType: ${error.errorType}
              isForMainFrame: ${error.isForMainFrame}
          ''');
          },
          onNavigationRequest: (NavigationRequest request) {
            if (request.url.startsWith('https://www.youtube.com/')) {
              debugPrint('blocking navigation to ${request.url}');
              return NavigationDecision.prevent;
            }
            debugPrint('allowing navigation to ${request.url}');
            return NavigationDecision.navigate;
          },
          onHttpError: (HttpResponseError error) {
            debugPrint('Error occurred on page: ${error.response?.statusCode}');
          },
          onUrlChange: (UrlChange change) async {
            debugPrint('url change to ${change.url}');
            String? url = change.url!;
            if (url.startsWith('http')) {
              //await launchUrl(Uri.parse(url));
              return;
            } else {
              try {
                await launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                );
                controller.loadRequest(Uri.parse(sbpUrl));
                if (!mounted) return;
              } on Object catch (_) {
                if (url.startsWith('intent')) {
                  controller.loadRequest(
                      Uri.parse(url.replaceFirst('intent', 'https')));
                  sbpUrl = url.replaceFirst('intent', 'https');
                } else {
                  AndroidFlutterLocalNotificationsPlugin().show(
                      0, 'Robokassa', 'У вас не установлено приложение банка',
                      notificationDetails: const AndroidNotificationDetails(
                          'wbrs', 'wbrs',
                          importance: Importance.max),
                      payload: 'test');
                  controller.loadRequest(Uri.parse(sbpUrl));
                }
              }
            }
          },
          onHttpAuthRequest: (HttpAuthRequest request) {},
        ),
      )
      ..addJavaScriptChannel(
        'Toaster',
        onMessageReceived: (JavaScriptMessage message) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message.message)),
          );
        },
      )
      ..loadRequest(Uri.parse(
          'https://auth.robokassa.ru/Merchant/Index.aspx?'
              'MerchantLogin=WBRS'
              '&OutSum=$outSum'
              '&InvId=${widget.count}'
              '&Description=${isTestMode ? "Test" : "Пополнение баланса"}'
              '&SignatureValue=$signature'
              '${isTestMode ? "&IsTest=1" : ""}'
      ));

    // setBackgroundColor is not currently supported on macOS.
    if (kIsWeb || !Platform.isMacOS) {
      controller.setBackgroundColor(const Color(0x80000000));
    }

    // #docregion platform_features
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
    // #enddocregion platform_features

    ctrl = controller;
    // Enable virtual display.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ctrl = WebViewController();
    super.dispose();
  }

  addSilver() async {
    int balance = await firebaseFirestore
        .collection('users')
        .doc(firebaseAuth.currentUser!.uid)
        .get()
        .then((value) => value['balance']);

    switch (widget.sum) {
      case '150':
        balance += 39;
        break;
      case '299':
        balance += 86;
        break;
      case '490':
        balance += 145;
        break;
      case '990':
        balance += 305;
        break;
      case '1490':
        balance += 490;
        break;
      case '2880':
        balance += 1020;
        break;
    }

    await firebaseFirestore
        .collection('users')
        .doc(firebaseAuth.currentUser!.uid)
        .update({'balance': balance});
    globalBalance = balance;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (value, result) async {
        String signatureStatus = md5
            .convert(utf8.encode('WBRS:${widget.count}:$password2'))
            .toString();
        String resultCode = '';
        var res = await http.post(
          Uri.parse(
              'https://auth.robokassa.ru/Merchant/WebService/Service.asmx/OpStateExt?MerchantLogin=WBRS&InvId=${widget.count}&Signature=$signatureStatus'),
          headers: <String, String>{'Content-Type': 'application/json'},
        );

        XmlDocument document = XmlDocument.parse(res.body);
        if (document.findAllElements('Code').first.innerText == '0') {
          resultCode = document.findAllElements('Code').elementAt(1).innerText;
        }
        print(resultCode);
        if (resultCode == '100') {
          addSilver();
          AndroidFlutterLocalNotificationsPlugin().show(
              0, 'Robokassa', 'Оплата прошла успешно',
              notificationDetails: const AndroidNotificationDetails(
                  'wbrs', 'wbrs',
                  importance: Importance.max),
              payload: 'test');
        } else {
          AndroidFlutterLocalNotificationsPlugin().show(
              0, 'Robokassa', 'Оплата не прошла',
              notificationDetails: const AndroidNotificationDetails(
                  'wbrs', 'wbrs',
                  importance: Importance.max, number: 2),
              payload: 'test');
        }
      },
      child: _progress < 100
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : WebViewWidget(
              controller: ctrl,
            ),
    );
  }
}
