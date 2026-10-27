import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/foundation.dart' show kDebugMode;

const kAppName = 'GS1 Scan';

// Database
const kDbName = 'gs1_scan.db';
const kDbVersion = 3;
const kTableScanRecords = 'scan_records';

const kColId = 'id';
const kColRawBarcode = 'raw_barcode';
const kColBarcodeFormat = 'barcode_format';
const kColBatchNumber = 'batch_number';
const kColGtin = 'gtin';
const kColExpiryDate = 'expiry_date';
const kColSerialNumber = 'serial_number';
const kColScanTimestamp = 'scan_timestamp';
const kColConfidenceScore = 'confidence_score';
const kColIsValid = 'is_valid';
const kColImagePath = 'image_path';
const kColMedicineName = 'medicine_name';
const kColStrength = 'strength';
const kColIsOcr = 'is_ocr';
const kColVerifiedByUser = 'verified_by_user';

// History
const kHistoryPageSize = 50;
const kManualBarcodeFormat = 'MANUAL';
const kOcrBarcodeFormat = 'OCR';

/// History card title when a record has no batch number.
const kUnrecognisedTitle = 'Unrecognised barcode';

// Scanning
const kConsensusWindow = 5;
const kConsensusRequired = 3;
const kConsensusTimeout = Duration(seconds: 10);
const kFrameMinInterval = Duration(milliseconds: 100);

/// 1080p. ResolutionPreset.max can be tried later if accuracy on tiny
/// barcodes needs it, but it can slow frame processing on budget phones.
const kCameraResolution = ResolutionPreset.veryHigh;

/// Logs raw barcode values (debug builds only).
const kDebugLogRaw = true;

/// What the code actually checks before logging a raw barcode: debug builds
/// only, whatever [kDebugLogRaw] says. Release and profile builds never log
/// scanned values.
const kLogRawBarcodes = kDebugLogRaw && kDebugMode;

/// When true, skip the camera and run the old 3-second mock scan. For
/// devices with no camera.
const kMockScanFallback = false;

// CSV export
const kCsvFilePrefix = 'gs1_scan_';
const kCsvMinFreeBytes = 5 * 1024 * 1024;

/// Write all-digit GTIN/serial cells as ="0123" so spreadsheets keep the
/// leading zeros.
const kCsvProtectLeadingZeros = true;

/// Column order of the export (exactly this).
const kCsvHeaders = [
  'Sr. No.',
  'Batch Number',
  'GTIN',
  'Expiry Date',
  'Serial Number',
  'Raw Barcode',
  'Barcode Format',
  'Scan Date & Time',
  'Valid',
  'Confidence',
];

const kPrefLastExportAt = 'last_export_at';

// Edge cases (Step 7)

/// The same raw barcode saved within this window is "Already scanned.".
const kDedupWindow = Duration(seconds: 3);

/// No detection for this long while scanning shows the "Having trouble?" card.
const kNoBarcodeHintAfter = Duration(seconds: 15);

/// A barcode narrower than this fraction of the frame counts as small.
const kMinBarcodeWidthFraction = 0.20;
const kAutoZoomLevel = 2.0;

/// Consecutive small detections before auto-zoom (about 0.6 s at 100 ms).
const kSmallBarcodeFramesBeforeZoom = 6;

/// Mean Y value (0..255) below which the scene counts as dark.
const kLowLightLuma = 45.0;
const kLowLightHoldTime = Duration(seconds: 1);

const kManualBatchMaxLength = 20;

// Accuracy test harness (release hygiene)

/// True only for builds made with --dart-define=ACCURACY_TEST=true. It is a
/// compile-time constant, so the harness code is removed (tree-shaken) from
/// every other build.
const kAccuracyTestEnabled = bool.fromEnvironment('ACCURACY_TEST');
