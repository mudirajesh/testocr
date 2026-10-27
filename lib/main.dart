import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'providers/batch_scan_provider.dart';
import 'providers/history_provider.dart';
import 'providers/scanner_provider.dart';
import 'screens/splash_screen.dart';
import 'services/barcode_scanner_service.dart';
import 'services/camera_availability.dart';
import 'services/csv_export_service.dart';
import 'services/database_service.dart';
import 'services/export_tracker.dart';
import 'theme/app_theme.dart';
import 'utils/constants.dart';

void main() {
  // The fonts are bundled (assets/google_fonts) and the release app has no
  // INTERNET permission, so never try to download them.
  GoogleFonts.config.allowRuntimeFetching = false;
  runApp(buildApp(source: MlKitBarcodeSource()));
}

/// Builds the whole app. Production passes only the camera [source]; the other
/// parameters exist so integration tests can replace the camera, the database,
/// the share sheet and the splash without changing how the app is wired.
Widget buildApp({
  required BarcodeDetectionSource source,
  DatabaseService? db,
  CameraAvailability cameraAvailability = const DeviceCameraAvailability(),
  ExportTracker? tracker,
  Future<Directory> Function()? exportTempDir,
  Future<void> Function(File file)? exportShare,
  Future<int?> Function()? exportFreeBytes,
  Widget home = const SplashScreen(),
}) {
  return GS1ScanApp(
    source: source,
    db: db ?? DatabaseService.instance,
    cameraAvailability: cameraAvailability,
    tracker: tracker,
    exportTempDir: exportTempDir,
    exportShare: exportShare,
    exportFreeBytes: exportFreeBytes,
    home: home,
  );
}

class GS1ScanApp extends StatelessWidget {
  const GS1ScanApp({
    super.key,
    required this.source,
    required this.db,
    required this.cameraAvailability,
    this.tracker,
    this.exportTempDir,
    this.exportShare,
    this.exportFreeBytes,
    this.home = const SplashScreen(),
  });

  final BarcodeDetectionSource source;
  final DatabaseService db;
  final CameraAvailability cameraAvailability;
  final ExportTracker? tracker;
  final Future<Directory> Function()? exportTempDir;
  final Future<void> Function(File file)? exportShare;
  final Future<int?> Function()? exportFreeBytes;
  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<CameraAvailabilityProvider>(
          // Not lazy: checked once at app start, without blocking it.
          lazy: false,
          create: (_) =>
              CameraAvailabilityProvider(cameraAvailability)..check(),
        ),
        Provider<ExportTracker>.value(value: tracker ?? ExportTracker()),
        Provider<CsvExportService>(
          // Not lazy: old export files are cleaned up once at app start.
          lazy: false,
          create: (context) => CsvExportService(
            db: context.read<DatabaseService>(),
            tempDir: exportTempDir,
            share: exportShare,
            freeBytes: exportFreeBytes,
          )..cleanupOldExports(),
        ),
        ChangeNotifierProvider<HistoryProvider>(
          // Not lazy: load at app start so the Home stats are ready.
          lazy: false,
          create: (context) => HistoryProvider(
            context.read<DatabaseService>(),
            exporter: context.read<CsvExportService>(),
            tracker: context.read<ExportTracker>(),
          )..loadInitial(),
        ),
        ChangeNotifierProvider<ScannerProvider>(
          create: (context) {
            final history = context.read<HistoryProvider>();
            return ScannerProvider(
              db: context.read<DatabaseService>(),
              source: source,
            )..onRecordSaved = () => history.refresh();
          },
        ),
        // Lazy: only created when the batch screen is opened. It shares the
        // camera source with ScannerProvider, but only one screen runs at a
        // time and each disposes the camera when it closes.
        ChangeNotifierProvider<BatchScanProvider>(
          create: (context) {
            final history = context.read<HistoryProvider>();
            return BatchScanProvider(
              db: context.read<DatabaseService>(),
              source: source,
            )..onRecordSaved = () => history.refresh();
          },
        ),
      ],
      child: MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: home,
      ),
    );
  }
}
