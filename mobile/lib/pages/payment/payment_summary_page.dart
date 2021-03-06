import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:enum_to_string/enum_to_string.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dialogs/flutter_dialogs.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:smart_car_park_app/models/parking_invoice.dart';
import 'package:smart_car_park_app/models/payment_intent.dart';
import 'package:smart_car_park_app/models/payment_method.dart';
import 'package:smart_car_park_app/models/payment_source.dart';
import 'package:smart_car_park_app/pages/payment/payment_complete_page.dart';
import 'package:smart_car_park_app/utils/cloud_functions_utils.dart';
import 'package:smart_car_park_app/widgets/parking_invoice_widget.dart';
import 'package:smart_car_park_app/widgets/progress_dialog.dart';
import 'package:stripe_sdk/stripe_sdk.dart';
import 'package:uni_links/uni_links.dart';
import 'package:url_launcher/url_launcher.dart';

class PaymentSummaryPage extends StatefulWidget {
  /// Used for card payment
  final PaymentIntent paymentIntent;
  final PaymentMethod paymentMethod;
  final Function updateCreditCards;

  /// Used for Alipay / WechatPay
  final PaymentSource paymentSource;

  PaymentSummaryPage({
    this.paymentIntent,
    this.paymentMethod,
    this.updateCreditCards,
    this.paymentSource,
  });

  @override
  _PaymentSummaryPageState createState() => _PaymentSummaryPageState();
}

class _PaymentSummaryPageState extends State<PaymentSummaryPage> {
  bool _needUpdateCreditCards() => widget.updateCreditCards != null;

  bool _isUsingPaymentIntent() => widget.paymentIntent != null;

  Future<bool> _pop() async {
    if (this._needUpdateCreditCards()) {
      widget.updateCreditCards();
    }
    return true;
  }

  void _pay() {
    if (this._isUsingPaymentIntent()) {
      this._completePaymentIntent();
    } else {
      this._createAndCompletePaymentSource();
    }
  }

  void _completePaymentIntent() async {
    Map<String, dynamic> response;
    ProgressDialog.show(context, message: "Processing payment...");
    try {
      response = await Stripe.instance.confirmPayment(
          widget.paymentIntent.clientSecret, widget.paymentMethod.id);
      await closeWebView();
      ProgressDialog.hide(context);
      this._handlePaymentIntentResponse(response);
    } catch (e) {
      print(e);
      ProgressDialog.hide(context);
      this._showPaymentErrorDialog(e.toString());
    }
  }

  void _createAndCompletePaymentSource() async {
    ProgressDialog.show(context, message: "Confirming payment...");
    Map response = await CloudFunctionsUtils.createPaymentSource(
        EnumToString.parse(widget.paymentSource.type),
        widget.paymentSource.gateRecordId);
    Map source = response["source"];

    /// Init payment
    if (widget.paymentSource.type == PaymentSourceType.alipay) {
      final returnUrl = Uri.parse(source['redirect']['return_url']);
      final completer = Completer();
      StreamSubscription sub;
      sub = getUriLinksStream().listen((Uri uri) async {
        if (uri.scheme == returnUrl.scheme && uri.host == returnUrl.host) {
          await sub.cancel();
          completer.complete();
        }
      });
      await launch(source["redirect"]["url"]);
      await completer.future;
      await closeWebView();
    } else if (widget.paymentSource.type == PaymentSourceType.wechat) {
      ProgressDialog.hide(context);
      showDialog(
        context: context,
        barrierDismissible: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    "Take a screenshot and import into\nWeChat's QR Code Scanner",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      decoration: TextDecoration.none,
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                QrImage(
                  data: source["wechat"]["qr_code_url"],
                  version: QrVersions.auto,
                  size: 300,
                  gapless: false,
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      CircularProgressIndicator(),
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0),
                        child: Text(
                          "Checking payment...",
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.normal,
                            decoration: TextDecoration.none,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    StreamSubscription recordSub;
    recordSub = Firestore.instance
        .collection("gateRecords")
        .document(widget.paymentSource.gateRecordId)
        .snapshots()
        .listen((snapshot) async {
      if (snapshot.data["paymentStatus"] == "succeeded") {
        recordSub.cancel();
        this._goToSuccessPage(widget.paymentSource.invoice.total);
      }
    });
  }

  void _handlePaymentIntentResponse(Map<String, dynamic> response) {
    if (response == null || response["status"] == "succeeded") {
      this._goToSuccessPage(widget.paymentIntent.invoice.total);
    } else {
      this._showPaymentErrorDialog("Payment has failed");
    }
  }

  void _goToSuccessPage(double amount) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) => PaymentCompletePage(
          amount: amount,
        ),
      ),
      ModalRoute.withName("/home"),
    );
  }

  void _showPaymentErrorDialog(String message) {
    showPlatformDialog(
      context: context,
      builder: (_) => BasicDialogAlert(
        title: Text("Payment failed"),
        content: Text(message),
        actions: <Widget>[
          BasicDialogAction(
            title: Text("OK"),
            onPressed: () {
              Navigator.pop(context);
              if (this._isUsingPaymentIntent() &&
                  widget.paymentMethod.customer == null) {
                /// Single use card, require setup again
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    );
  }

  String _getPaymentMethodText() {
    if (this._isUsingPaymentIntent()) {
      return widget.paymentMethod.card.getCardDescription();
    } else {
      return widget.paymentSource.type.getName();
    }
  }

  Color _getPaymentColor() {
    if (this._isUsingPaymentIntent()) {
      return Theme.of(context).primaryColor;
    } else {
      return Colors.white;
    }
  }

  Color _getPaymentTextColor() {
    if (this._isUsingPaymentIntent()) {
      return Colors.white;
    } else {
      return Colors.black;
    }
  }

  Color _getPaymentButtonSplashColor() {
    if (this._isUsingPaymentIntent()) {
      return Colors.indigoAccent;
    } else {
      return Colors.grey[200];
    }
  }

  ParkingInvoice _getParkingInvoice() {
    if (this._isUsingPaymentIntent()) {
      return widget.paymentIntent.invoice;
    } else {
      return widget.paymentSource.invoice;
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: this._pop,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Confirmation'),
          leading: IconButton(
            icon: Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.maybePop(context);
            },
          ),
        ),
        body: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Expanded(
                child: ParkingInvoiceWidget(
                  invoice: this._getParkingInvoice(),
                ),
              ),
              Container(
                margin: EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                child: RaisedButton(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(36),
                  ),
                  color: this._getPaymentColor(),
                  textColor: this._getPaymentTextColor(),
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (!this._isUsingPaymentIntent())
                        Padding(
                          padding: const EdgeInsets.only(right: 16.0),
                          child: Image(
                            width: 30,
                            height: 30,
                            image: AssetImage(
                                widget.paymentSource.type.getAssetPath()),
                          ),
                        ),
                      Text("Pay with ${this._getPaymentMethodText()}"),
                      Icon(Icons.navigate_next)
                    ],
                  ),
                  onPressed: this._pay,
                  splashColor: this._getPaymentButtonSplashColor(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
