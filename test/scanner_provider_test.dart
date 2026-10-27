import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/providers/scanner_provider.dart';
import 'package:gs1scan/services/barcode_scanner_service.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:gs1scan/utils/constants.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

// Valid GS1 strings: GTIN 08901234567890, expiry 31/12/2026.
const goodRaw = '01089012345678901726123110BN2024X981';
const otherRaw = '01089012345678901726123110LOTB1';
const gtinOnlyRaw = '0108901234567890';
const urlRaw = 'https://example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  /// Builds a provider on fakes and runs [body] in fake time.
  void scenario(
    String description,
    void Function(
      FakeAsync async,
      ScannerProvider provider,
      FakeBarcodeSource source,
      FakeDb db,
    )
    body,
  ) {
    test(description, () {
      fakeAsync((async) {
        final source = FakeBarcodeSource();
        final db = FakeDb();
        final provider = ScannerProvider(db: db, source: source);
        body(async, provider, source, db);
        provider.dispose();
      });
    });
  }

  void startScanning(FakeAsync async, ScannerProvider provider) {
    provider.start();
    async.flushMicrotasks();
  }

  void feed(
    FakeAsync async,
    FakeBarcodeSource source,
    String raw, {
    String format = 'dataMatrix',
  }) {
    source.emit(raw, format: format);
    async.flushMicrotasks();
  }

  void feedTimes(
    FakeAsync async,
    FakeBarcodeSource source,
    String raw,
    int times, {
    String format = 'dataMatrix',
  }) {
    for (var i = 0; i < times; i++) {
      feed(async, source, raw, format: format);
    }
  }

  /// Distinct values every second until the 10 s consensus timeout fires.
  void runToTimeout(FakeAsync async, FakeBarcodeSource source) {
    feed(async, source, 'READ-0', format: 'qrCode');
    for (var i = 1; i < 10; i++) {
      async.elapse(const Duration(seconds: 1));
      feed(async, source, 'READ-$i', format: 'qrCode');
    }
    async.elapse(const Duration(seconds: 1));
  }

  group('scanning flow', () {
    scenario('start leads to scanning', (async, provider, source, db) {
      expect(provider.status, ScannerStatus.initializing);
      startScanning(async, provider);
      expect(provider.status, ScannerStatus.scanning);
      expect(source.startCalls, 1);
    });

    scenario('first detection moves to processing', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feed(async, source, goodRaw);
      expect(provider.status, ScannerStatus.processing);
    });

    scenario('3 matching detections succeed with parsed fields', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);

      expect(provider.status, ScannerStatus.success);
      final record = provider.result!;
      expect(record.batchNumber, 'BN2024X981');
      expect(record.gtin, '08901234567890');
      expect(record.expiryDate, '261231');
      expect(record.confidenceScore, closeTo(0.6, 1e-9));
      expect(record.barcodeFormat, 'DataMatrix');
      expect(record.isValid, isTrue);
      expect(provider.parseResult!.isValid, isTrue);
      expect(source.pauseCalls, 1);
    });

    scenario('A, B, A, A succeeds despite a misread', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feed(async, source, goodRaw);
      feed(async, source, '01089012345678901726123110BN2O24X981');
      feed(async, source, goodRaw);
      expect(provider.status, ScannerStatus.processing);
      feed(async, source, goodRaw);

      expect(provider.status, ScannerStatus.success);
      expect(provider.result!.batchNumber, 'BN2024X981');
    });

    scenario('Code 128 with GS1 data is labelled GS1-128', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3, format: 'code128');
      expect(provider.result!.barcodeFormat, 'GS1-128');
    });

    scenario('2 seconds without detections returns to scanning', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feed(async, source, goodRaw);
      expect(provider.status, ScannerStatus.processing);

      source.emitNone();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(provider.status, ScannerStatus.processing);

      async.elapse(const Duration(seconds: 1));
      expect(provider.status, ScannerStatus.scanning);

      // The buffer was reset: two more reads are not enough for consensus.
      feedTimes(async, source, goodRaw, 2);
      expect(provider.status, ScannerStatus.processing);
    });

    scenario('CameraUnavailableException gives noCamera', (
      async,
      provider,
      source,
      db,
    ) {
      source.startError = CameraUnavailableException();
      startScanning(async, provider);
      expect(provider.status, ScannerStatus.noCamera);
    });

    scenario('CameraPermissionDeniedException gives permissionDenied', (
      async,
      provider,
      source,
      db,
    ) {
      source.startError = CameraPermissionDeniedException();
      startScanning(async, provider);
      expect(provider.status, ScannerStatus.permissionDenied);
    });

    scenario('an unknown start failure gives error with a message', (
      async,
      provider,
      source,
      db,
    ) {
      source.startError = StateError('boom');
      startScanning(async, provider);
      expect(provider.status, ScannerStatus.error);
      expect(provider.errorMessage, contains('boom'));
    });

    scenario('torch toggles and reaches the source', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      provider.toggleTorch();
      async.flushMicrotasks();
      expect(provider.torchOn, isTrue);
      expect(source.lastTorch, isTrue);
      provider.toggleTorch();
      async.flushMicrotasks();
      expect(provider.torchOn, isFalse);
      expect(source.lastTorch, isFalse);
    });

    scenario('app pause and resume pause and resume the source', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      provider.onAppPaused();
      async.flushMicrotasks();
      expect(source.pauseCalls, 1);
      provider.onAppResumed();
      async.flushMicrotasks();
      expect(source.resumeCalls, 1);
    });

    test('dispose twice does not throw', () {
      final provider = ScannerProvider(
        db: FakeDb(),
        source: FakeBarcodeSource(),
      );
      provider.dispose();
      expect(provider.dispose, returnsNormally);
    });
  });

  group('saving', () {
    scenario('a valid consensus scan is saved before success', (
      async,
      provider,
      source,
      db,
    ) {
      var saved = 0;
      provider.onRecordSaved = () => saved++;
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);

      expect(provider.status, ScannerStatus.success);
      expect(provider.isSaved, isTrue);
      expect(provider.saveFailed, isFalse);
      expect(db.rows.length, 1);
      expect(db.rows.single.batchNumber, 'BN2024X981');
      expect(saved, 1);
    });

    scenario('consensus on a non-GS1 value needs review and is not saved', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, urlRaw, 3, format: 'qrCode');

      expect(provider.status, ScannerStatus.needsReview);
      expect(db.rows, isEmpty);
      expect(provider.isSaved, isFalse);
      expect(provider.result!.isValid, isFalse);
      expect(provider.result!.barcodeFormat, 'QR');
      expect(provider.issues, contains('Unrecognised barcode format'));
    });

    scenario('timeout gives lowConfidence, nothing saved; Save Anyway keeps '
        'isValid false', (async, provider, source, db) {
      startScanning(async, provider);
      runToTimeout(async, source);

      expect(provider.status, ScannerStatus.lowConfidence);
      expect(db.rows, isEmpty);
      expect(provider.isSaved, isFalse);
      expect(provider.result!.isValid, isFalse);

      bool? saved;
      provider.saveCurrent().then((v) => saved = v);
      async.flushMicrotasks();

      expect(saved, isTrue);
      expect(provider.isSaved, isTrue);
      expect(db.rows.length, 1);
      expect(db.rows.single.isValid, isFalse);
      expect(provider.result!.isValid, isFalse);
    });

    scenario('saveCurrent called twice inserts once', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, urlRaw, 3, format: 'qrCode');

      final results = <bool>[];
      provider.saveCurrent().then(results.add);
      provider.saveCurrent().then(results.add);
      async.flushMicrotasks();
      provider.saveCurrent().then(results.add);
      async.flushMicrotasks();

      expect(results, [true, true, true]);
      expect(db.insertCalls, 1);
      expect(db.rows.length, 1);
    });

    scenario('a failing database returns false and never throws', (
      async,
      provider,
      source,
      db,
    ) {
      db.failInsert = true;
      startScanning(async, provider);
      feedTimes(async, source, urlRaw, 3, format: 'qrCode');
      expect(provider.status, ScannerStatus.needsReview);

      bool? saved;
      provider.saveCurrent().then((v) => saved = v);
      async.flushMicrotasks();

      expect(saved, isFalse);
      expect(provider.saveFailed, isTrue);
      expect(provider.isSaved, isFalse);

      // Recovers once the database works again.
      db.failInsert = false;
      provider.saveCurrent().then((v) => saved = v);
      async.flushMicrotasks();
      expect(saved, isTrue);
      expect(provider.saveFailed, isFalse);
      expect(provider.isSaved, isTrue);
    });

    scenario('a valid scan whose auto-save fails goes to review', (
      async,
      provider,
      source,
      db,
    ) {
      db.failInsert = true;
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);

      expect(provider.status, ScannerStatus.needsReview);
      expect(provider.saveFailed, isTrue);
      expect(provider.result!.isValid, isTrue);
    });

    scenario('rescan clears saved and failed flags and the result', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      expect(provider.isSaved, isTrue);

      provider.rescan();
      async.flushMicrotasks();

      expect(provider.status, ScannerStatus.scanning);
      expect(provider.isSaved, isFalse);
      expect(provider.saveFailed, isFalse);
      expect(provider.result, isNull);
      expect(provider.parseResult, isNull);
      expect(source.resumeCalls, 1);
    });
  });

  group('same-barcode lockout', () {
    scenario('the same barcode is ignored after rescan until it leaves view', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      expect(db.rows.length, 1);

      provider.rescan();
      async.flushMicrotasks();
      expect(provider.status, ScannerStatus.scanning);

      // Still under the camera: ignored, status stays scanning.
      feedTimes(async, source, goodRaw, 6);
      expect(provider.status, ScannerStatus.scanning);
      expect(db.rows.length, 1);

      // Seen every second: the out-of-view clock keeps restarting.
      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(seconds: 1));
        feed(async, source, goodRaw);
      }
      expect(provider.status, ScannerStatus.scanning);
      expect(db.rows.length, 1);
    });

    scenario('a different barcode is accepted immediately', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      provider.rescan();
      async.flushMicrotasks();

      feedTimes(async, source, otherRaw, 3);

      expect(provider.status, ScannerStatus.success);
      expect(db.rows.length, 2);
      expect(db.rows.last.batchNumber, 'LOTB1');
    });

    scenario('the same value is accepted again after 1500 ms out of view', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      provider.rescan();
      async.flushMicrotasks();

      feedTimes(async, source, goodRaw, 2); // ignored
      source.emitNone();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1500));
      // Out of view for 1.5 s releases the lockout; the 3 s duplicate window
      // has also passed by the time it is back.
      db.elapsed += const Duration(seconds: 4);

      feedTimes(async, source, goodRaw, 3);

      expect(provider.status, ScannerStatus.success);
      expect(db.rows.length, 2);
    });

    scenario('ignored detections never enter the consensus buffer', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      provider.rescan();
      async.flushMicrotasks();

      feedTimes(async, source, goodRaw, 5); // locked out
      async.elapse(const Duration(milliseconds: 1500));
      // If the ignored frames had been buffered, 1 more would reach consensus.
      feed(async, source, goodRaw);
      expect(provider.status, ScannerStatus.processing);
    });

    scenario('an unsaved low-confidence barcode is not locked out', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      runToTimeout(async, source);
      expect(provider.status, ScannerStatus.lowConfidence);

      provider.rescan();
      async.flushMicrotasks();
      feed(async, source, 'READ-9', format: 'qrCode');
      expect(provider.status, ScannerStatus.processing);
    });
  });

  group('issues', () {
    scenario('include parser warnings', (async, provider, source, db) {
      startScanning(async, provider);
      feedTimes(async, source, gtinOnlyRaw, 3);

      expect(provider.status, ScannerStatus.success);
      expect(provider.issues, contains('No batch/lot number in this barcode'));
    });

    scenario('include the low-confidence line on timeout', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      runToTimeout(async, source);

      expect(provider.status, ScannerStatus.lowConfidence);
      expect(
        provider.issues.first,
        'Low confidence: only 1 of 5 frames agreed',
      );
      expect(provider.issues, contains('Unrecognised barcode format'));
    });

    scenario('are empty before any result', (async, provider, source, db) {
      startScanning(async, provider);
      expect(provider.issues, isEmpty);
    });
  });

  group('with a real in-memory database', () {
    late DatabaseService realDb;
    late FakeBarcodeSource source;
    late ScannerProvider provider;

    setUp(() {
      realDb = DatabaseService.forTesting(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      source = FakeBarcodeSource();
      provider = ScannerProvider(db: realDb, source: source);
    });

    tearDown(() async {
      provider.dispose();
      await realDb.close();
    });

    Future<void> waitFor(bool Function() condition) async {
      for (var i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('a valid scan is stored and onRecordSaved fires once', () async {
      var saved = 0;
      provider.onRecordSaved = () => saved++;
      await provider.start();

      for (var i = 0; i < 3; i++) {
        source.emit(goodRaw);
        await pumpEventQueue();
      }
      await waitFor(() => provider.status == ScannerStatus.success);

      expect(provider.status, ScannerStatus.success);
      expect(await realDb.count(), 1);
      expect(provider.isSaved, isTrue);
      expect(saved, 1);

      final stored = await realDb.getById(provider.result!.id);
      expect(stored, isNotNull);
      expect(stored!.batchNumber, 'BN2024X981');
      expect(stored.gtin, '08901234567890');
      expect(stored.expiryDate, '261231');
      expect(stored.confidenceScore, closeTo(0.6, 1e-9));
      expect(stored.isValid, isTrue);
    });

    test('a non-GS1 scan stays out of the database until saved', () async {
      await provider.start();
      for (var i = 0; i < 3; i++) {
        source.emit(urlRaw, format: 'qrCode');
        await pumpEventQueue();
      }
      await waitFor(() => provider.status == ScannerStatus.needsReview);

      expect(provider.status, ScannerStatus.needsReview);
      expect(await realDb.count(), 0);

      expect(await provider.saveCurrent(), isTrue);
      expect(await realDb.count(), 1);
      final stored = await realDb.getById(provider.result!.id);
      expect(stored!.isValid, isFalse);
      expect(stored.status, ScanStatus.alert);
    });
  });

  // --------------------------------------------------------------- Step 7

  /// Distinct non-GS1 values never reach consensus, so they only exercise the
  /// zoom / hint logic.
  void feedDistinct(
    FakeAsync async,
    FakeBarcodeSource source,
    int count, {
    double width = 0.5,
    String prefix = 'D',
  }) {
    for (var i = 0; i < count; i++) {
      source.emit('$prefix$i', format: 'qrCode', widthFraction: width);
      async.flushMicrotasks();
    }
  }

  group('camera permission', () {
    scenario('a first denial is not permanent', (async, provider, source, db) {
      source.startError = const CameraPermissionDeniedException();
      startScanning(async, provider);

      expect(provider.status, ScannerStatus.permissionDenied);
      expect(provider.permissionPermanentlyDenied, isFalse);
    });

    scenario('a permanent denial is flagged', (async, provider, source, db) {
      source.startError = const CameraPermissionDeniedException(
        permanent: true,
      );
      startScanning(async, provider);

      expect(provider.status, ScannerStatus.permissionDenied);
      expect(provider.permissionPermanentlyDenied, isTrue);
    });

    scenario('Allow camera (start again) recovers and clears the flag', (
      async,
      provider,
      source,
      db,
    ) {
      source.startError = const CameraPermissionDeniedException(
        permanent: true,
      );
      startScanning(async, provider);
      expect(provider.permissionPermanentlyDenied, isTrue);

      source.startError = null;
      startScanning(async, provider);

      expect(provider.status, ScannerStatus.scanning);
      expect(provider.permissionPermanentlyDenied, isFalse);
    });

    scenario('resuming after allowing the camera in Settings starts scanning', (
      async,
      provider,
      source,
      db,
    ) {
      source.startError = const CameraPermissionDeniedException(
        permanent: true,
      );
      startScanning(async, provider);
      expect(source.startCalls, 1);

      // The user comes back from Settings with the permission granted.
      source.startError = null;
      source.permissionGranted = true;
      provider.onAppResumed();
      async.flushMicrotasks();

      expect(provider.status, ScannerStatus.scanning);
      expect(source.startCalls, 2);
    });

    scenario('resuming while still denied does not prompt or loop', (
      async,
      provider,
      source,
      db,
    ) {
      source.startError = const CameraPermissionDeniedException(
        permanent: true,
      );
      source.permissionGranted = false;
      startScanning(async, provider);

      provider.onAppResumed();
      provider.onAppResumed();
      async.flushMicrotasks();

      expect(provider.status, ScannerStatus.permissionDenied);
      expect(source.startCalls, 1);
    });
  });

  group('duplicates', () {
    scenario('the same raw within 3 s is Already scanned and not saved', (
      async,
      provider,
      source,
      db,
    ) {
      final messages = <String>[];
      provider.messages.listen(messages.add);
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      expect(provider.status, ScannerStatus.success);
      expect(db.rows.length, 1);

      provider.rescan();
      async.flushMicrotasks();
      // Out of view long enough to release the lockout, but still < 3 s.
      source.emitNone();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1600));
      db.elapsed += const Duration(milliseconds: 1600);
      feedTimes(async, source, goodRaw, 3);

      expect(messages, ['Already scanned.']);
      expect(db.rows.length, 1);
      expect(provider.status, ScannerStatus.scanning);
      expect(provider.result, isNull);
    });

    scenario('the same raw after 3 s is accepted again', (
      async,
      provider,
      source,
      db,
    ) {
      final messages = <String>[];
      provider.messages.listen(messages.add);
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);

      provider.rescan();
      async.flushMicrotasks();
      source.emitNone();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1600));
      db.elapsed += kDedupWindow + const Duration(milliseconds: 100);
      feedTimes(async, source, goodRaw, 3);

      expect(messages, isEmpty);
      expect(provider.status, ScannerStatus.success);
      expect(db.rows.length, 2);
    });

    scenario('a duplicate keeps scanning and shows the message once', (
      async,
      provider,
      source,
      db,
    ) {
      final messages = <String>[];
      provider.messages.listen(messages.add);
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      provider.rescan();
      async.flushMicrotasks();
      source.emitNone();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1600));
      db.elapsed += const Duration(milliseconds: 1600);
      feedTimes(async, source, goodRaw, 3);
      expect(messages.length, 1);

      // Back in scanning with the lockout armed: more frames of the same
      // barcode produce no second message and no record.
      feedTimes(async, source, goodRaw, 6);
      expect(messages.length, 1);
      expect(db.rows.length, 1);
      expect(source.resumeCalls, greaterThanOrEqualTo(2));
    });

    scenario('a failing duplicate lookup does not block scanning', (
      async,
      provider,
      source,
      db,
    ) {
      db.failExists = true;
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);

      expect(provider.status, ScannerStatus.success);
      expect(db.rows.length, 1);
    });

    scenario('a timed-out read of a just-saved barcode is also skipped', (
      async,
      provider,
      source,
      db,
    ) {
      final messages = <String>[];
      provider.messages.listen(messages.add);
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      expect(db.rows.length, 1);

      provider.rescan();
      async.flushMicrotasks();

      // Another value first (releases the lockout), then a window in which the
      // saved barcode is the most common value but never reaches 3.
      feed(async, source, 'other-1');
      final pattern = [
        'o2',
        'o3',
        'o4',
        'o5',
        'o6',
        goodRaw,
        'o7',
        goodRaw,
        'o8',
      ];
      for (final raw in pattern) {
        async.elapse(const Duration(seconds: 1));
        feed(async, source, raw);
      }
      async.elapse(const Duration(seconds: 1)); // the 10 s timeout

      expect(messages, ['Already scanned.']);
      expect(provider.status, ScannerStatus.scanning);
      expect(db.rows.length, 1);
    });
  });

  group('no-barcode help', () {
    scenario('appears after 15 s without detections and clears on one', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      async.elapse(kNoBarcodeHintAfter - const Duration(seconds: 1));
      expect(provider.showTroubleHint, isFalse);

      async.elapse(const Duration(seconds: 1));
      expect(provider.showTroubleHint, isTrue);

      feed(async, source, goodRaw);
      expect(provider.showTroubleHint, isFalse);
    });

    scenario('the timer restarts on every detection', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      async.elapse(const Duration(seconds: 10));
      feed(async, source, goodRaw);
      async.elapse(const Duration(seconds: 1));
      source.emitNone();
      async.flushMicrotasks();

      // 10 s + 1 s + 14 s since the detection's restart would be 15 s only
      // after the detection, so it is still hidden here.
      async.elapse(const Duration(seconds: 13));
      expect(provider.showTroubleHint, isFalse);
    });

    scenario('dismissing hides it until the next 15 s period', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      async.elapse(kNoBarcodeHintAfter);
      expect(provider.showTroubleHint, isTrue);

      provider.dismissTroubleHint();
      expect(provider.showTroubleHint, isFalse);
      async.elapse(const Duration(seconds: 14));
      expect(provider.showTroubleHint, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(provider.showTroubleHint, isTrue);
    });

    scenario('an open sheet clears it and keeps it away', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      async.elapse(kNoBarcodeHintAfter);
      expect(provider.showTroubleHint, isTrue);

      provider.setSheetOpen(true);
      expect(provider.showTroubleHint, isFalse);
      async.elapse(const Duration(seconds: 40));
      expect(provider.showTroubleHint, isFalse);
    });

    scenario('rescan restarts the 15 s period', (async, provider, source, db) {
      startScanning(async, provider);
      async.elapse(const Duration(seconds: 10));
      provider.rescan();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 14));
      expect(provider.showTroubleHint, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(provider.showTroubleHint, isTrue);
    });
  });

  group('low light', () {
    scenario('appears after 1 s below the threshold', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      source.emitBrightness(kLowLightLuma - 10);
      async.flushMicrotasks();
      async.elapse(kLowLightHoldTime - const Duration(milliseconds: 1));
      expect(provider.lowLight, isFalse);

      async.elapse(const Duration(milliseconds: 1));
      expect(provider.lowLight, isTrue);
    });

    scenario('clears as soon as it brightens', (async, provider, source, db) {
      startScanning(async, provider);
      source.emitBrightness(10);
      async.flushMicrotasks();
      async.elapse(kLowLightHoldTime);
      expect(provider.lowLight, isTrue);

      source.emitBrightness(120);
      async.flushMicrotasks();
      expect(provider.lowLight, isFalse);
    });

    scenario('a brief dark moment does not trigger it', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      source.emitBrightness(10);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 500));
      source.emitBrightness(120);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      expect(provider.lowLight, isFalse);
    });

    scenario('turning the torch on clears it', (async, provider, source, db) {
      startScanning(async, provider);
      source.emitBrightness(10);
      async.flushMicrotasks();
      async.elapse(kLowLightHoldTime);
      expect(provider.lowLight, isTrue);

      provider.toggleTorch();
      async.flushMicrotasks();

      expect(provider.torchOn, isTrue);
      expect(provider.lowLight, isFalse);
    });

    scenario('does not nag for 20 s after the torch was switched off', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      provider.toggleTorch(); // on
      async.flushMicrotasks();
      provider.toggleTorch(); // off again
      async.flushMicrotasks();

      source.emitBrightness(10);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(provider.lowLight, isFalse);

      async.elapse(const Duration(seconds: 11)); // past the 20 s pause
      source.emitBrightness(10);
      async.flushMicrotasks();
      async.elapse(kLowLightHoldTime);
      expect(provider.lowLight, isTrue);
    });
  });

  group('torch support', () {
    scenario('a device without a flash is reported unsupported', (
      async,
      provider,
      source,
      db,
    ) {
      source.torchResult = false;
      startScanning(async, provider);
      expect(provider.torchSupported, isTrue); // not known until tried

      bool? ok;
      provider.toggleTorch().then((v) => ok = v);
      async.flushMicrotasks();

      expect(ok, isFalse);
      expect(provider.torchSupported, isFalse);
      expect(provider.torchOn, isFalse);

      // Further taps do not even reach the camera.
      source.lastTorch = null;
      provider.toggleTorch();
      async.flushMicrotasks();
      expect(source.lastTorch, isNull);
    });
  });

  group('auto-zoom', () {
    scenario('a small barcode zooms in to 2x exactly once', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedDistinct(
        async,
        source,
        kSmallBarcodeFramesBeforeZoom - 1,
        width: 0.1,
      );
      expect(source.zoomCalls, isEmpty);
      expect(provider.barcodeTooSmall, isTrue);
      expect(provider.isZoomed, isFalse);

      feedDistinct(async, source, 1, width: 0.1, prefix: 'Z');
      expect(source.zoomCalls, [kAutoZoomLevel]);
      expect(provider.isZoomed, isTrue);

      feedDistinct(async, source, 5, width: 0.1, prefix: 'Y');
      expect(source.zoomCalls, [kAutoZoomLevel]);
    });

    scenario('rescan resets the zoom to 1x', (async, provider, source, db) {
      startScanning(async, provider);
      feedDistinct(async, source, kSmallBarcodeFramesBeforeZoom, width: 0.1);
      expect(provider.isZoomed, isTrue);

      provider.rescan();
      async.flushMicrotasks();

      expect(source.zoomCalls, [kAutoZoomLevel, 1.0]);
      expect(provider.isZoomed, isFalse);
      expect(provider.barcodeTooSmall, isFalse);
    });

    scenario('zooms back out once the barcode is large again', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedDistinct(async, source, kSmallBarcodeFramesBeforeZoom, width: 0.1);
      expect(provider.isZoomed, isTrue);

      feedDistinct(async, source, 5, width: 0.6, prefix: 'L');
      expect(source.zoomCalls, [kAutoZoomLevel, 1.0]);
      expect(provider.isZoomed, isFalse);
      expect(provider.barcodeTooSmall, isFalse);
    });

    scenario('never zooms when the device cannot', (
      async,
      provider,
      source,
      db,
    ) {
      source.supportsZoom = false;
      startScanning(async, provider);
      feedDistinct(async, source, 10, width: 0.1);

      expect(source.zoomCalls, isEmpty);
      expect(provider.isZoomed, isFalse);
      expect(provider.barcodeTooSmall, isTrue); // still tells the user
    });

    scenario('a normal-size barcode never zooms', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedDistinct(async, source, 10, width: 0.35);
      expect(source.zoomCalls, isEmpty);
      expect(provider.barcodeTooSmall, isFalse);
    });

    scenario('resuming the app resets the zoom', (async, provider, source, db) {
      startScanning(async, provider);
      feedDistinct(async, source, kSmallBarcodeFramesBeforeZoom, width: 0.1);
      provider.onAppPaused();
      async.flushMicrotasks();
      provider.onAppResumed();
      async.flushMicrotasks();

      expect(source.zoomCalls, [kAutoZoomLevel, 1.0]);
      expect(provider.isZoomed, isFalse);
    });
  });

  group('runtime errors', () {
    scenario('a camera error moves to the error status', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedDistinct(async, source, 1);
      source.emitError(StateError('camera disconnected'));
      async.flushMicrotasks();

      expect(provider.status, ScannerStatus.error);
      expect(provider.errorMessage, isNot(contains('disconnected')));
    });

    scenario('Try again restarts the camera after an error', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      source.emitError(StateError('boom'));
      async.flushMicrotasks();
      expect(provider.status, ScannerStatus.error);

      provider.start();
      async.flushMicrotasks();

      expect(provider.status, ScannerStatus.scanning);
      expect(source.startCalls, 2);
    });

    scenario('an error while a sheet is open waits for rescan to restart', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 3);
      expect(provider.status, ScannerStatus.success);

      source.emitError(StateError('boom'));
      async.flushMicrotasks();
      expect(provider.status, ScannerStatus.success);

      provider.rescan();
      async.flushMicrotasks();
      expect(source.startCalls, 2);
      expect(provider.status, ScannerStatus.scanning);
    });

    scenario('errors never escape, even repeated', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      for (var i = 0; i < 10; i++) {
        source.emitError(StateError('boom $i'));
        async.flushMicrotasks();
      }
      expect(provider.status, ScannerStatus.error);
    });
  });

  group('lifecycle', () {
    scenario('no resume after backgrounding while a sheet is open', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feed(async, source, goodRaw);
      provider.setSheetOpen(true);

      provider.onAppPaused();
      async.flushMicrotasks();
      provider.onAppResumed();
      async.flushMicrotasks();
      expect(source.resumeCalls, 0);

      provider.setSheetOpen(false);
      provider.onAppResumed();
      async.flushMicrotasks();
      expect(source.resumeCalls, 1);
    });

    scenario('background and return keeps the partial consensus', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedTimes(async, source, goodRaw, 2);
      expect(provider.status, ScannerStatus.processing);

      provider.onAppPaused();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 60)); // no timeout in background
      expect(provider.status, ScannerStatus.processing);

      provider.onAppResumed();
      async.flushMicrotasks();
      expect(source.resumeCalls, 1);

      feed(async, source, goodRaw); // the third matching frame
      expect(provider.status, ScannerStatus.success);
    });

    scenario('the consensus timeout restarts fresh after resuming', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedDistinct(async, source, 1);
      async.elapse(const Duration(seconds: 8));
      provider.onAppPaused();
      async.flushMicrotasks();
      provider.onAppResumed();
      async.flushMicrotasks();

      // 8 s were already used, but the clock restarted: 9 s later is fine
      // as long as frames keep arriving.
      for (var i = 0; i < 9; i++) {
        async.elapse(const Duration(seconds: 1));
        feedDistinct(async, source, 1, prefix: 'R$i');
      }
      expect(provider.status, ScannerStatus.processing);

      async.elapse(const Duration(seconds: 2));
      expect(provider.status, ScannerStatus.lowConfidence);
    });

    scenario('manual entry pauses the camera and resumes it afterwards', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);

      provider.pauseForExternalScreen();
      async.flushMicrotasks();
      expect(source.pauseCalls, 1);

      // Backgrounding and returning while manual entry is open must not
      // restart the camera behind it.
      provider.onAppPaused();
      provider.onAppResumed();
      async.flushMicrotasks();
      expect(source.resumeCalls, 0);

      provider.resumeAfterExternalScreen();
      async.flushMicrotasks();
      expect(source.resumeCalls, 1);
    });

    scenario('stop releases everything and nothing fires afterwards', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      feedDistinct(async, source, 3);
      source.emitBrightness(5);
      async.flushMicrotasks();

      provider.stop();
      async.flushMicrotasks();
      expect(source.disposeCalls, greaterThanOrEqualTo(1));

      // Timers were cancelled: nothing changes however long we wait.
      async.elapse(const Duration(minutes: 1));
      expect(provider.lowLight, isFalse);
      expect(provider.showTroubleHint, isFalse);
    });

    test('no notification after dispose', () {
      fakeAsync((async) {
        final source = FakeBarcodeSource();
        final provider = ScannerProvider(db: FakeDb(), source: source);
        var notified = 0;
        provider.addListener(() => notified++);
        provider.start();
        async.flushMicrotasks();
        feedDistinct(async, source, 1);
        final before = notified;

        provider.dispose();
        async.elapse(const Duration(minutes: 1));
        source.emitBrightness(1);
        async.flushMicrotasks();

        expect(notified, before);
      });
    });
  });

  group('speed metrics', () {
    scenario('an accepted scan records its timing', (
      async,
      provider,
      source,
      db,
    ) {
      source.averageFrameMillis = 95;
      startScanning(async, provider);
      expect(provider.lastMetrics, isNull);

      feedTimes(async, source, goodRaw, 3);

      final metrics = provider.lastMetrics!;
      expect(metrics.firstDetectionMs, greaterThanOrEqualTo(0));
      expect(metrics.consensusMs, greaterThanOrEqualTo(0));
      expect(metrics.averageFrameMs, 95);
      expect(metrics.format(), contains('avgFrame=95ms'));
    });

    scenario('a timed-out scan records its timing too', (
      async,
      provider,
      source,
      db,
    ) {
      startScanning(async, provider);
      runToTimeout(async, source);

      expect(provider.status, ScannerStatus.lowConfidence);
      expect(provider.lastMetrics, isNotNull);
    });
  });
}
