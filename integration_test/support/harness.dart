import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/main.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/screens/home_screen.dart';
import 'package:gs1scan/services/camera_availability.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:gs1scan/services/export_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../test/support/fakes.dart';

/// A valid GS1 DataMatrix: GTIN 08901234567890, expiry 31/12/2026, batch
/// BN2024X981.
const validGs1 = '01089012345678901726123110BN2024X981';

class _HasCamera implements CameraAvailability {
  @override
  Future<bool> hasCamera() async => true;
}

/// The whole app with a fake camera, an in-memory database and a fake share
/// sheet: the same provider wiring as production (via buildApp).
///
/// These tests run with `flutter test integration_test` on the host (the
/// database uses sqflite's FFI build there) or on a device/emulator (the
/// platform sqflite is used).
class AppHarness {
  AppHarness._(this.source, this.db, this.tempDir);

  final FakeBarcodeSource source;
  final DatabaseService db;
  final Directory tempDir;

  /// Files handed to the (fake) share sheet.
  final List<File> shared = [];

  static Future<AppHarness> create() async {
    SharedPreferences.setMockInitialValues({});
    final onDevice = Platform.isAndroid || Platform.isIOS;
    if (!onDevice) sqfliteFfiInit();
    final db = DatabaseService.forTesting(
      factory: onDevice ? null : databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final tempDir = await Directory.systemTemp.createTemp('gs1_integration');
    return AppHarness._(FakeBarcodeSource(), db, tempDir);
  }

  Future<void> dispose() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }

  Future<void> seed(List<ScanRecord> records) => db.insertAll(records);

  Widget app() => buildApp(
    source: source,
    db: db,
    cameraAvailability: _HasCamera(),
    tracker: ExportTracker(),
    exportTempDir: () async => tempDir,
    exportShare: (file) async => shared.add(file),
    exportFreeBytes: () async => null,
    home: const HomeScreen(),
  );

  /// Pumps the app on a phone-sized screen.
  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await settle(tester);
  }

  /// Emits [raw] as [times] consecutive detections, one frame apart.
  Future<void> detect(
    WidgetTester tester,
    String raw, {
    int times = 3,
    String format = 'dataMatrix',
  }) async {
    for (var i = 0; i < times; i++) {
      source.emit(raw, format: format);
      await tester.pump(const Duration(milliseconds: 60));
    }
  }
}

/// Lets timers, animations and database calls run. Not pumpAndSettle: the
/// scan screen's scan line animates forever.
Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var elapsed = 0; elapsed < ms; elapsed += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps until [finder] matches, or fails after [timeout].
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

/// Pumps until [finder] no longer matches.
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder to disappear');
}

/// Home -> Scan screen, waiting until the (fake) camera is running.
Future<void> openScanScreen(WidgetTester tester) async {
  await tester.tap(find.text('Scan Barcode'));
  await pumpUntilFound(tester, find.text('Scanning...'));
}

ScanRecord sampleRecord(int i, {bool isValid = true}) => ScanRecord(
  id: 'seed-$i',
  rawBarcode: 'raw-$i',
  barcodeFormat: 'DataMatrix',
  batchNumber: 'SEED-$i',
  gtin: '08901234567890',
  expiryDate: '271231',
  scanTimestamp: DateTime.now().subtract(Duration(minutes: 10 + i)),
  confidenceScore: 1.0,
  isValid: isValid,
);
