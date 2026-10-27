import 'scan_record.dart';

/// What happened to one item of a batch scan session.
enum BatchItemState {
  /// Parsed fine and written to the database.
  saved,

  /// Intent to save, but the database write threw.
  saveFailed,

  /// No GS1 data at all (a plain QR, a URL, ...): skipped, not saved.
  unrecognised,
}

/// One barcode handled during a batch scan session, with how it ended up.
class BatchScanItem {
  const BatchScanItem(this.record, {this.state = BatchItemState.saved});

  final ScanRecord record;
  final BatchItemState state;

  bool get isSaved => state == BatchItemState.saved;

  /// Short label for the session list and summary.
  String get stateLabel {
    switch (state) {
      case BatchItemState.saved:
        return 'Saved';
      case BatchItemState.saveFailed:
        return 'Save failed';
      case BatchItemState.unrecognised:
        return 'Unrecognised';
    }
  }
}
