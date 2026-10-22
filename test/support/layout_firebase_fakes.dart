// Test-only doubles for Firestore interfaces; no production data or SDK calls.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

class LayoutUser extends Fake implements User {
  @override
  String get uid => 'viewer';
  @override
  String get displayName => 'Участник';
  @override
  String? get photoURL => null;
}

class LayoutAuth extends Fake implements FirebaseAuth {
  User? user = LayoutUser();
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => Stream.value(user);
}

class LayoutMessaging extends Fake implements FirebaseMessaging {
  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      const NotificationSettings(
          alert: AppleNotificationSetting.enabled,
          announcement: AppleNotificationSetting.disabled,
          authorizationStatus: AuthorizationStatus.authorized,
          badge: AppleNotificationSetting.enabled,
          carPlay: AppleNotificationSetting.disabled,
          lockScreen: AppleNotificationSetting.enabled,
          notificationCenter: AppleNotificationSetting.enabled,
          showPreviews: AppleShowPreviewSetting.always,
          sound: AppleNotificationSetting.enabled,
          criticalAlert: AppleNotificationSetting.disabled,
          providesAppNotificationSettings: AppleNotificationSetting.disabled,
          timeSensitive: AppleNotificationSetting.disabled);
}

class LayoutFirestore extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  final queryRows =
      <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
  bool serveEmittedQueries = false;
  int fetchedDocuments = 0;
  int fetchedQueries = 0;
  int streamedDocuments = 0;
  final streams =
      <String, StreamController<QuerySnapshot<Map<String, dynamic>>>>{};
  final gets = <String, Future<DocumentSnapshot<Map<String, dynamic>>>>{};
  final subscriptions = <String, int>{};
  int commits = 0;
  int transactions = 0;
  int updates = 0;
  Future<void> Function(String path, Map<Object, Object?> data)? updateHandler;
  int nextId = 0;
  Completer<void>? commitGate;
  Object? commitError;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      LayoutCollection(this, path);
  @override
  WriteBatch batch() => LayoutBatch(this);
  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler,
      {Duration timeout = const Duration(seconds: 30),
      int maxAttempts = 5}) async {
    transactions++;
    final tx = LayoutTransaction(this);
    final value = await handler(tx);
    await commitGate?.future;
    if (commitError != null) throw commitError!;
    final before = {
      for (final entry in documents.entries)
        entry.key: Map<String, dynamic>.from(entry.value)
    };
    try {
      for (final operation in tx.operations) {
        await operation();
      }
    } catch (_) {
      documents
        ..clear()
        ..addAll(before);
      rethrow;
    }
    commits++;
    return value;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watch(String path) => streams
      .putIfAbsent(
          path,
          () => StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast(
              onListen: () =>
                  subscriptions.update(path, (n) => n + 1, ifAbsent: () => 1)))
      .stream;
  void emit(String path, List<Map<String, dynamic>> rows,
      {List<String>? ids}) {
    assert(ids == null || ids.length == rows.length);
    final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[
      for (var i = 0; i < rows.length; i++)
        LayoutSnapshot(this, '$path/${ids == null ? i : ids[i]}', rows[i]),
    ];
    queryRows[path] = docs;
    streams[path]?.add(LayoutQuerySnapshot(docs));
  }

  Future<void> close() async {
    for (final stream in streams.values) {
      await stream.close();
    }
  }
}

class LayoutCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  LayoutCollection(this.db, this.path, {this.queryLimit, this.afterId});
  final int? queryLimit;
  final String? afterId;
  final LayoutFirestore db;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      LayoutReference(db, '${this.path}/${path ?? 'generated-${db.nextId++}'}');
  @override
  Query<Map<String, dynamic>> orderBy(Object field,
          {bool descending = false}) =>
      this;
  @override
  Query<Map<String, dynamic>> limit(int limit) =>
      LayoutCollection(db, path, queryLimit: limit, afterId: afterId);
  @override
  Query<Map<String, dynamic>> startAfterDocument(DocumentSnapshot documentSnapshot) =>
      LayoutCollection(db, path, queryLimit: queryLimit, afterId: documentSnapshot.id);
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots(
          {bool includeMetadataChanges = false,
          ListenSource source = ListenSource.defaultSource}) =>
      db.watch(path).map((snapshot) {
        final selected = snapshot.docs
            .skip(_startAt(snapshot.docs))
            .take(queryLimit ?? snapshot.docs.length)
            .toList();
        if (db.serveEmittedQueries) db.streamedDocuments += selected.length;
        return LayoutQuerySnapshot(selected);
      });
  int _startAt(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    if (afterId == null) return 0;
    final index = docs.indexWhere((doc) => doc.id == afterId);
    return index < 0 ? 0 : index + 1;
  }
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get(
          [GetOptions? options]) async {
    if (!db.serveEmittedQueries) return LayoutQuerySnapshot([]);
    final docs = db.queryRows[path] ?? [];
    final selected = docs
        .skip(_startAt(docs))
        .take(queryLimit ?? docs.length)
        .toList();
    db.fetchedQueries++;
    db.fetchedDocuments += selected.length;
    return LayoutQuerySnapshot(selected);
  }
  @override
  Future<DocumentReference<Map<String, dynamic>>> add(
      Map<String, dynamic> data) async {
    final ref = doc();
    await ref.set(data);
    return ref;
  }
}

class LayoutReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  LayoutReference(this.db, this.path);
  final LayoutFirestore db;
  @override
  final String path;
  @override
  String get id => path.split('/').last;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      LayoutCollection(db, '${this.path}/$path');
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get(
          [GetOptions? options]) async =>
      db.gets[path] ??
      Future.value(LayoutSnapshot(db, path, db.documents[path]));
  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots(
          {bool includeMetadataChanges = false,
          ListenSource source = ListenSource.defaultSource}) =>
      Stream.multi((controller) {
        // Firestore permits resubscription when a lazy list remounts its fields.
        controller.add(LayoutSnapshot(db, path, db.documents[path]));
        controller.close();
      }, isBroadcast: true);
  @override
  Future<void> update(Map<Object, Object?> data) async {
    db.updates++;
    if (db.updateHandler != null) {
      await db.updateHandler!(path, data);
      return;
    }
    db.documents[path]!.addAll(data.cast<String, dynamic>());
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    db.documents[path] = data;
  }
}

class LayoutSnapshot extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  LayoutSnapshot(this.db, this.path, this.value);
  final LayoutFirestore db;
  final String path;
  final Map<String, dynamic>? value;
  @override
  String get id => path.split('/').last;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic> data() => value ?? {};
  @override
  dynamic get(Object field) => value?[field];
  @override
  dynamic operator [](Object field) => get(field);
  @override
  DocumentReference<Map<String, dynamic>> get reference =>
      LayoutReference(db, path);
}

class LayoutQuerySnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  LayoutQuerySnapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class LayoutBatch extends Fake implements WriteBatch {
  LayoutBatch(this.db);
  final LayoutFirestore db;
  final operations = <void Function()>[];
  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    operations.add(() =>
        db.documents[document.path] = Map<String, dynamic>.from(data as Map));
  }

  @override
  void update(DocumentReference document, Map<String, dynamic> data) {
    operations.add(() => db.documents[document.path]!.addAll(data));
  }

  @override
  Future<void> commit() async {
    db.commits++;
    if (db.commitGate != null) await db.commitGate!.future;
    if (db.commitError != null) throw db.commitError!;
    for (final operation in operations) {
      operation();
    }
  }
}

class LayoutTransaction extends Fake implements Transaction {
  LayoutTransaction(this.db);
  final LayoutFirestore db;
  final operations = <Future<void> Function()>[];
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
          DocumentReference<T> ref) async =>
      await LayoutReference(db, ref.path).get() as DocumentSnapshot<T>;
  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    operations.add(() async {
      db.documents[ref.path] = Map<String, dynamic>.from(data as Map);
    });
    return this;
  }

  @override
  Transaction update(DocumentReference ref, Map<String, dynamic> data) {
    operations.add(() => LayoutReference(db, ref.path).update(data));
    return this;
  }
}
