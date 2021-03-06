import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_car_park_app/pages/snapshot_page.dart';
import 'package:timeline_list/timeline.dart';
import 'package:timeline_list/timeline_model.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:intl/intl.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:smart_car_park_app/global_variables.dart';

import '../models/parking_invoice.dart';
import '../models/user_record.dart';
import '../utils/cloud_functions_utils.dart';
import 'payment/payment_methods_page.dart';

class InformationPage extends StatefulWidget {
  InformationPage({key}) : super(key: key);

  @override
  _InformationPageState createState() => _InformationPageState();
}

class _InformationPageState extends State<InformationPage> {
  DocumentSnapshot _gateRecord;
  String _currentLocation;
  List<Map<String, dynamic>> _iotStateChangesPrev = [];
  List<Map<String, dynamic>> _iotStateChangesNew = [];
  List<Map<String, dynamic>> _iotStateChanges = [];

  StreamSubscription _gateRecordSubscription;
  StreamSubscription _iotStateChangesPrevSubscription;
  StreamSubscription _iotStateChangesNewSubscription;
  StreamSubscription _snapshotSubscription;

  String _iotImageUrl;
  ParkingInvoice _invoice;

  Future<void> listenToGateRecord() async {
    String phoneNumber =
        Provider.of<UserRecord>(context, listen: false).phoneNumber;
    await this._gateRecordSubscription?.cancel();
    this._gateRecordSubscription = null;
    this._gateRecordSubscription = Firestore.instance
        .collection('gateRecords')
        .where('phoneNumber', isEqualTo: phoneNumber)
        .snapshots(includeMetadataChanges: true)
        .listen((snapshot) async {
      try {
        var sortedGateRecords = snapshot.documents
          ..sort((a, b) => -1 * (a.data["entryScanTime"] as Timestamp)
              .compareTo(b.data["entryScanTime"] as Timestamp));
        this._gateRecord = sortedGateRecords.first;
        this.requestParkingInvoice();
        this.listenToIotStateChanges();
      } catch (e) {
        print(e);
        this._gateRecord = null;
      } finally {
        setState(() {});
      }
    });
  }

  void requestParkingInvoice() async {
    if (this._gateRecord["paymentStatus"] != "succeeded") {
      ParkingInvoice invoice = await CloudFunctionsUtils.getParkingInvoice(
          this._gateRecord.documentID);
      setState(() {
        this._invoice = invoice;
      });
    }
  }

  void listenToIotStateChanges() async {
    await this._iotStateChangesPrevSubscription?.cancel();
    this._iotStateChangesPrevSubscription = null;
    await this._iotStateChangesNewSubscription?.cancel();
    this._iotStateChangesNewSubscription = null;
    if (this._gateRecord == null || this._gateRecord['vehicleId'] == null) {
      this._iotStateChangesNew = [];
      this._iotStateChangesPrev = [];
      this._iotStateChanges = [];
      setState(() {});
      return;
    }
    final vehicleId = this._gateRecord['vehicleId'] as String;
    this._iotStateChangesPrevSubscription = Firestore.instance
        .collection('iotStateChanges')
        .where('previousState.vehicleId', isEqualTo: vehicleId)
        .snapshots()
        .listen((snapshot) {
      this._iotStateChangesPrev =
          snapshot.documents.map((snapshot) => snapshot.data).toList();
      this._iotStateChanges = [
        ...this._iotStateChangesPrev,
        ...this._iotStateChangesNew
      ]
        ..sort((a, b) =>
            -1 * (a['time'] as Timestamp).compareTo(b['time'] as Timestamp))
        ..removeWhere((data) => !isWithinCurrentGateRecordTime(
            (data["time"] as Timestamp).toDate()));
      this.refreshCurrentLocation();
      setState(() {});
    });
    this._iotStateChangesNewSubscription = Firestore.instance
        .collection('iotStateChanges')
        .where('newState.vehicleId', isEqualTo: vehicleId)
        .snapshots()
        .listen((snapshot) {
      this._iotStateChangesNew = snapshot.documents
          .map((snapshot) => snapshot.data)
          .toList()
            ..removeWhere((data) => (data["time"] as Timestamp)
                .toDate()
                .isBefore(
                    (_gateRecord['entryScanTime'] as Timestamp).toDate()));
      this._iotStateChanges = [
        ...this._iotStateChangesPrev,
        ...this._iotStateChangesNew
      ]
        ..sort((a, b) =>
            -1 * (a['time'] as Timestamp).compareTo(b['time'] as Timestamp))
        ..removeWhere((data) => !isWithinCurrentGateRecordTime(
            (data["time"] as Timestamp).toDate()));
      this.refreshCurrentLocation();
      setState(() {});
    });
  }

  void refreshCurrentLocation() {
    final lastVacant = this._iotStateChanges.firstWhere(
        (change) => change['newState']['state'] == 'vacant',
        orElse: () => null);
    final lastOccupy = this._iotStateChanges.firstWhere(
        (change) => change['newState']['state'] == 'occupied',
        orElse: () => null);
    if (lastVacant != null &&
        lastOccupy != null &&
        (lastVacant['time'] as Timestamp)
                .compareTo(lastOccupy['time'] as Timestamp) >
            0) {
      // vacant is later then occupy
      _currentLocation = null;
    } else if (lastOccupy != null) {
      _currentLocation = lastOccupy['deviceId'];
    } else {
      _currentLocation = null;
    }
    this.listenToSnapshot();
  }

  void listenToSnapshot() async {
    this._snapshotSubscription?.cancel();
    this._snapshotSubscription = null;
    if (this._currentLocation == null) {
      this._iotImageUrl = null;
      return;
    }
    Firestore.instance
        .document('iotStates/${this._currentLocation}')
        .snapshots()
        .listen((snapshot) async {
      debugPrint(snapshot.data.toString());
      if (!(snapshot.data['imageUrl'] as String).startsWith('gs://')) return;
      final ref = await FirebaseStorage.instance
          .getReferenceFromUrl(snapshot.data['imageUrl'] as String);
      this._iotImageUrl = (await ref.getDownloadURL()) as String;
      debugPrint(_iotImageUrl);
      setState(() {});
    });
  }

  void logout() {
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text('Logging out'),
            content: Text('Are you sure?'),
            actions: <Widget>[
              FlatButton(
                child: Text('Cancel'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              FlatButton(
                child: Text(
                  'Confirm',
                  style: TextStyle(
                    color: Colors.red,
                  ),
                ),
                onPressed: () {
                  FirebaseAuth.instance.signOut();
                  userRecord.reset();
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        });
  }

  bool _shouldPay() => this._invoice != null && (this._gateRecord?.data["paymentStatus"] ?? "") != "succeeded";

  @override
  void initState() {
    super.initState();
    this.listenToGateRecord();
  }

  bool isWithinCurrentGateRecordTime(DateTime dateTime) {
    return (_gateRecord['entryScanTime'] != null
            ? dateTime
                .isAfter((_gateRecord['entryScanTime'] as Timestamp).toDate())
            : true) &&
        (_gateRecord['exitScanTime'] != null
            ? dateTime
                .isBefore((_gateRecord['exitScanTime'] as Timestamp).toDate())
            : true);
  }

  Widget makeTableRow(String title, String subtitle) {
    return Padding(
      padding: EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Padding(
              padding: EdgeInsets.only(left: 8, right: 8),
              child: Text(
                title,
                style: Theme.of(context).primaryTextTheme.subtitle1,
                textAlign: TextAlign.right,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Padding(
              padding: EdgeInsets.only(left: 8, right: 8),
              child: Text(
                subtitle,
                style: Theme.of(context).primaryTextTheme.subtitle1,
                textAlign: TextAlign.left,
              ),
            ),
          ),
        ],
      ),
    );
  }

  TimelineModel makeChangeTimelineModel(Map<String, dynamic> iotStateChange) {
    String message = '';
    if (iotStateChange['newState']['state'] == 'occupied') {
      message = 'Vehicle parked into ${iotStateChange['deviceId']}';
    } else if (iotStateChange['newState']['state'] == 'vacant') {
      message = 'Vehicle moved out of ${iotStateChange['deviceId']}';
    } else {
      message =
          'Status changed from ${iotStateChange['previousState']['state']} to ${iotStateChange['newState']['state']} at ${iotStateChange['deviceId']}';
    }
    return TimelineModel(
      Container(
        padding: EdgeInsets.symmetric(vertical: 4.0),
        width: double.maxFinite,
        child: Card(
          child: Padding(
              padding: EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodyText1,
                  ),
                  Padding(padding: EdgeInsets.only(top: 8.0)),
                  Text(
                    timeago
                        .format((iotStateChange['time'] as Timestamp).toDate()),
                    style: Theme.of(context).textTheme.caption,
                  ),
                ],
              )),
        ),
      ),
      icon: Icon(
        Icons.history,
        color: Colors.white,
      ),
      iconBackground: Theme.of(context).accentColor,
      position: TimelineItemPosition.left,
    );
  }

  TimelineModel makeMessageTimelineModel(
      {String message, String caption, IconData iconData}) {
    return TimelineModel(
      Container(
        padding: EdgeInsets.symmetric(vertical: 4.0),
        width: double.infinity,
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodyText1,
                ),
                Padding(padding: EdgeInsets.only(top: 8.0)),
                Text(
                  caption,
                  style: Theme.of(context).textTheme.caption,
                ),
              ],
            ),
          ),
        ),
      ),
      icon: Icon(
        iconData,
        color: Colors.white,
      ),
      iconBackground: Theme.of(context).accentColor,
      position: TimelineItemPosition.left,
    );
  }

  TimelineModel makeSnapshotTimelineModel(String imageUrl) {
    return TimelineModel(
        GestureDetector(
          onTap: () {
            // TODO: request new image
          },
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 4.0),
            width: double.maxFinite,
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Image.network(imageUrl),
                    Padding(padding: EdgeInsets.only(top: 8.0)),
                    Text(
                      "Click to request new snapshot",
                      style: Theme.of(context).textTheme.caption,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        icon: Icon(
          Icons.linked_camera,
          color: Colors.white,
        ),
        iconBackground: Theme.of(context).accentColor,
        position: TimelineItemPosition.left);
  }

  void _showDebugChangeVehicleIdDialog() {
    String vehicleId = "";
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Change vehicle ID"),
          content: TextField(
            onChanged: (text) => vehicleId = text,
          ),
          actions: <Widget>[
            FlatButton(
              child: Text('Confirm'),
              onPressed: () async {
                await Firestore.instance
                    .collection("gateRecords")
                    .document(this._gateRecord.documentID)
                    .setData({"vehicleId": vehicleId}, merge: true);
                this.listenToGateRecord();
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: this._gateRecord != null
            ? Text(DateFormat('yyyy-MM-dd').format(
                (this._gateRecord['entryScanTime'] as Timestamp).toDate()))
            : null,
        leading: IconButton(
          icon: Icon(Icons.account_circle),
          onPressed: this.logout,
        ),
        actions: <Widget>[
          IconButton(
            icon: Icon(Icons.access_time),
            onPressed: () {
              setState(() {
                // TODO: implement gate record list and selection
              });
            },
          ),
        ],
        bottom: this._gateRecord != null
            ? PreferredSize(
                preferredSize: Size.fromHeight(180.0),
                child: Container(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: <Widget>[
                      GestureDetector(
                        onLongPress: this._showDebugChangeVehicleIdDialog,
                        child: makeTableRow(
                            'Vehicle ID', this._gateRecord['vehicleId'] ?? '-'),
                      ),
                      makeTableRow(
                          'Parked Location', this._currentLocation ?? '-'),
                      makeTableRow(
                          'Parked Duration',
                          this._gateRecord['entryConfirmTime'] != null
                              ? DateTime.now()
                                      .difference(
                                          (this._gateRecord['entryConfirmTime']
                                                  as Timestamp)
                                              .toDate())
                                      .inMinutes
                                      .toString() +
                                  ' Minutes'
                              : '-'),
                      makeTableRow(
                          'Amount Due',
                          this._invoice == null
                              ? "-"
                              : "\$${this._invoice?.total}"),
                      Row(
                        children: <Widget>[
                          Expanded(
                            flex: 5,
                            child: FlatButton(
                              color: Colors.white.withAlpha(40),
                              textColor: Colors.white,
                              child: Text('View Snapshots'),
                              onPressed: this._currentLocation != null
                                  ? () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => SnapshotPage(
                                            iotDeviceId: this._currentLocation,
                                            fromDateTime: (this._gateRecord[
                                                        'entryScanTime']
                                                    as Timestamp)
                                                ?.toDate(),
                                          ),
                                        ),
                                      );
                                    }
                                  : null,
                            ),
                          ),
                          Padding(padding: EdgeInsets.only(left: 8.0)),
                          Expanded(
                            flex: 5,
                            child: FlatButton(
                              color: Colors.white.withAlpha(40),
                              textColor: Colors.white,
                              child: Text('Pay Amount'),
                              onPressed: this._shouldPay()
                                  ? () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              PaymentMethodsPage(
                                            gateRecordId:
                                                this._gateRecord.documentID,
                                          ),
                                        ),
                                      );
                                    }
                                  : null,
                            ),
                          )
                        ],
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: this._gateRecord != null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Timeline(
                children: <TimelineModel>[
                  // TODO: make exit time card
                  this._iotImageUrl != null
                      ? makeSnapshotTimelineModel(this._iotImageUrl)
                      : null,
                  ..._iotStateChanges
                      .map((change) => makeChangeTimelineModel(change))
                      .toList(),
                  makeMessageTimelineModel(
                      message:
                          'Entered Park via ${this._gateRecord['entryGate']} Gate',
                      caption: timeago.format(
                          (this._gateRecord['entryScanTime'] as Timestamp)
                              .toDate()),
                      iconData: Icons.exit_to_app)
                ].where((elem) => elem != null).toList(),
                position: TimelinePosition.Left,
                physics: BouncingScrollPhysics(),
              ),
            )
          : Center(
              child: CircularProgressIndicator(),
            ),
    );
  }
}
