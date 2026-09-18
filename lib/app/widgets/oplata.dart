import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/robokassa_webview.dart';
import 'package:wbrs/app/widgets/widgets.dart';

class OplataPage extends StatefulWidget {
  final String sum;
  const OplataPage({super.key, required this.sum});

  @override
  State<OplataPage> createState() => _OplataPageState();
}

class _OplataPageState extends State<OplataPage> {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 200,
      child: Column(children: [
        const Text(
          'Виды оплат',
          style: TextStyle(fontSize: 20, color: Colors.white),
        ),
        PopScope(
          child: ElevatedButton(
              onPressed: () async {
                int count = 0;
                await firebaseFirestore
                    .collection('transaction')
                    .get()
                    .then((value) {
                  count = value.docs.length + 1;
                });
                if (context.mounted) {
                  nextScreen(
                      context,
                      RobokassaWebview(
                        sum: widget.sum,
                        count: count,
                      ));
                }
              },
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text('Оплата СБП'), Icon(Icons.credit_card)],
              )),
        ),
        ElevatedButton(
            onPressed: () {
              showDialog(
                  context: context,
                  builder: (context) {
                    return SizedBox(
                      height: 300,
                      width: 300,
                      child: AlertDialog(
                        backgroundColor: Colors.white,
                        title: const Text('QR-код для оплаты'),
                        content: Image.asset('assets/pay/qr.jpeg'),
                      ),
                    );
                  });
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text('QR-код оплатa'), Icon(Icons.qr_code)],
            )),
      ]),
    );
  }
}
