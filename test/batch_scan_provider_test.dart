import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/batch_scan_item.dart';
import 'package:gs1scan/providers/batch_scan_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

// Valid GS1 strings: GTIN 08901234567890, expiry 31/12/2026.
const goodRaw = '01089012345678901726123110BN2024X981';
const otherRaw = '01089012345678901726123110LOTB1';
const urlRaw = 'https://example.com';

/// Same as the provider's private idle reset.
const idleReset = Duration(seconds: 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  /// Builds a provider on fakes and runs [body] in fake time.
  void scenario(
    String description,
    void Function(
      FakeAsync async,
      BatchScanProvider provider,
      FakeBarcodeSource source,
      FakeDb db,
    )
    body,
  ) {
    test(description, () {
      fakeAsync((async) {
        final source = FakeBarcodeSource();
        final db = FakeDb();
        final provider = BatchScanProvider(db: db, source: source);
        body(async, provider, source, db);
        provider.dispose();
      });
    });
  }

  void startBatch(FakeAsync async, BatchScanProvider provider) {
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

  /// Out of view long enough for the lockout and the idle reset to finish.
  void leaveView(FakeAsync async) {
    async.elapse(idleReset);
  }

  group('batch flow', () {
    scenario('start leads to scanning', (async, provider, source, db) {
      expect(provider.status, BatchScanStatus.initializing);
      startBatch(async, provider);
      expect(provider.status, BatchScanStatus.scanning);
      expect(source.startCalls, 1);
    });

    scenario('3 matching detections save and keep scanning', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);

      // Still running: batch mode never pauses for a result.
      expect(source.pauseCalls, 0);
      expect(provider.status, BatchScanStatus.scanning);
      expect(provider.savedCount, 1);
      expect(provider.items.single.state, BatchItemState.saved);

      final record = provider.items.single.record;
      expect(record.batchNumber, 'BN2024X981');
      expect(record.gtin, '08901234567890');
      expect(record.expiryDate, '261231');
      expect(record.confidenceScore, closeTo(0.6, 1e-9));
      expect(record.barcodeFormat, 'DataMatrix');
      expect(record.isValid, isTrue);
      expect(db.insertCalls, 1);
    });

    scenario('different barcodes stack up in the session', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);
      feedTimes(async, source, otherRaw, 3);

      expect(provider.items.length, 2);
      expect(provider.items.first.record.batchNumber, 'LOTB1');
      expect(provider.items.last.record.batchNumber, 'BN2024X981');
      expect(db.insertCalls, 2);
    });

    scenario('work continues on the detection path while a save is in flight', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);
      feedTimes(async, source, otherRaw, 1);
      expect(provider.items.length, 1);
      feedTimes(async, source, otherRaw, 2);
      expect(provider.items.length, 2);
    });

    scenario('the just-scanned barcode is ignored until it leaves view', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);
      expect(provider.savedCount, 1);

      // Still front of the camera: filtered by the lockout.
      feedTimes(async, source, goodRaw, 5);
      expect(provider.savedCount, 1);
      expect(db.insertCalls, 1);

      // Out of view long enough: it can be read again, and is a session
      // duplicate, so it is not saved twice.
      leaveView(async);
      feedTimes(async, source, goodRaw, 3);
      expect(provider.savedCount, 1);
      expect(db.insertCalls, 1);
    });

    scenario('a different barcode arriving releases the lockout', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);
      feedTimes(async, source, otherRaw, 3);
      // Straight back to the second one once a different barcode appeared.
      feedTimes(async, source, otherRaw, 3);
      expect(provider.items.length, 2);
    });

    scenario('a standalone lot code is saved as the batch number', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, 'BN2024X981', 3, format: 'code39');

      expect(provider.savedCount, 1);
      expect(provider.items.single.record.batchNumber, 'BN2024X981');
      expect(provider.items.single.record.isValid, isTrue);
      expect(db.insertCalls, 1);
    });

    scenario('unrecognised barcodes are skipped, listed, not saved', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, urlRaw, 3);

      expect(provider.savedCount, 0);
      expect(provider.skippedCount, 1);
      expect(provider.items.single.state, BatchItemState.unrecognised);
      expect(provider.items.single.record.rawBarcode, urlRaw);
      expect(db.insertCalls, 0);
    });

    scenario('a skipped barcode can be read again after leaving view', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, urlRaw, 3);
      leaveView(async);
      feedTimes(async, source, urlRaw, 3);

      // Not saved, so it is not locked out as a session duplicate: another
      // unrecognised item is listed.
      expect(provider.skippedCount, 2);
    });

    scenario('GS1 data with a parse error is saved flagged invalid', (
      async,
      provider,
      source,
      db,
    ) {
      // Known AIs, but the expiry value is not a date. The parser flags it,
      // and since fields exist the scan is kept (as an alert in history).
      startBatch(async, provider);
      feedTimes(async, source, '010890123456789017999910STAT', 3);

      expect(provider.savedCount, 1);
      expect(provider.items.single.record.isValid, isFalse);
      expect(provider.items.single.record.gtin, '08901234567890');
      expect(db.insertCalls, 1);
    });

    scenario('a failed database write is recorded, not lost', (
      async,
      provider,
      source,
      db,
    ) {
      db.failInsert = true;
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);

      expect(provider.items.single.state, BatchItemState.saveFailed);
      expect(provider.savedCount, 0);
      expect(provider.skippedCount, 1);
      // Continuous mode: the camera is still running.
      expect(source.pauseCalls, 0);
    });

    scenario('messages report session duplicates and skips', (
      async,
      provider,
      source,
      db,
    ) {
      final messages = <String>[];
      provider.messages.listen(messages.add);

      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);
      leaveView(async);
      feedTimes(async, source, goodRaw, 3);
      feedTimes(async, source, urlRaw, 3);

      expect(messages, contains('Already scanned · Skipped'));
      expect(messages, contains('Unrecognised barcode · Skipped'));
    });

    scenario('10 seconds without consensus reset the read, not the camera', (
      async,
      provider,
      source,
      db,
    ) {
      final messages = <String>[];
      provider.messages.listen(messages.add);

      startBatch(async, provider);
      // Contradicting reads on a 3-value cycle so no five-frame window can
      // ever agree on one value; one entry a second keeps the idle reset away.
      for (var i = 0; i < 12; i++) {
        feed(async, source, 'READ-${i % 3}', format: 'qrCode');
        async.elapse(const Duration(seconds: 1));
      }

      expect(provider.status, BatchScanStatus.scanning);
      // The contradicting reads were never saved.
      expect(provider.items, isEmpty);
      expect(messages.where((m) => m.contains('Hold steady')), isNotEmpty);
    });

    scenario('stop releases the camera and closes the session', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);
      provider.stop();
      async.flushMicrotasks();

      expect(source.disposeCalls, 1);
    });

    scenario('torch toggling reports an unusable flash', (
      async,
      provider,
      source,
      db,
    ) {
      source.torchResult = false;
      startBatch(async, provider);

      var ok = true;
      unawaited(provider.toggleTorch().then((v) => ok = v));
      async.flushMicrotasks();

      expect(ok, isFalse);
      expect(provider.torchSupported, isFalse);
    });
  });

  group('batch counters', () {
    scenario('saved and skipped counts reflect the session', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      feedTimes(async, source, goodRaw, 3);
      feedTimes(async, source, urlRaw, 3);

      expect(provider.savedCount, 1);
      expect(provider.skippedCount, 1);
      expect(provider.isEmpty, isFalse);
    });

    scenario('the mock scan goes through the normal flow', (
      async,
      provider,
      source,
      db,
    ) {
      startBatch(async, provider);
      provider.mockScanOnce();
      async.flushMicrotasks();

      expect(provider.savedCount, 1);
      expect(
        provider.items.single.record.rawBarcode,
        '(01)08901234567890(17)261231(10)BN2024X981',
      );

      // A second one is a session duplicate.
      provider.mockScanOnce();
      async.flushMicrotasks();
      expect(provider.savedCount, 1);
      expect(provider.items.length, 1);
    });
  });
}
