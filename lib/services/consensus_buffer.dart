import '../utils/constants.dart';

class ConsensusResult {
  const ConsensusResult({
    required this.raw,
    required this.format,
    required this.matches,
    required this.confidence,
    required this.reachedConsensus,
  });

  final String raw;
  final String format;
  final int matches;

  /// matches / window size, so 3 of 5 = 0.6 and 5 of 5 = 1.0.
  final double confidence;
  final bool reachedConsensus;
}

class _Entry {
  const _Entry(this.raw, this.format);

  final String raw;
  final String format;
}

/// Rolling buffer that makes the scanner agree with itself across frames.
///
/// Only frames that detected a barcode are added. Values are compared
/// exactly (case-sensitive, untrimmed): cleaning is the parser's job, so
/// "BN2024X981" and "BN2O24X981" are different values and never combine.
class ConsensusBuffer {
  ConsensusBuffer({
    this.window = kConsensusWindow,
    this.required = kConsensusRequired,
  });

  final int window;
  final int required;
  final List<_Entry> _entries = [];

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// Adds a detection. Returns a consensus result once at least [required]
  /// entries in the window equal [raw], otherwise null.
  ConsensusResult? add(String raw, String format) {
    _entries.add(_Entry(raw, format));
    if (_entries.length > window) _entries.removeAt(0);

    final matches = _entries.where((e) => e.raw == raw).length;
    if (matches < required) return null;
    return ConsensusResult(
      raw: raw,
      format: format,
      matches: matches,
      confidence: matches / window,
      reachedConsensus: true,
    );
  }

  /// Most common value in the window; ties go to the most recently seen.
  ConsensusResult? bestSoFar() {
    if (_entries.isEmpty) return null;

    final counts = <String, int>{};
    final lastSeen = <String, int>{};
    for (var i = 0; i < _entries.length; i++) {
      final raw = _entries[i].raw;
      counts[raw] = (counts[raw] ?? 0) + 1;
      lastSeen[raw] = i;
    }

    String? best;
    for (final raw in counts.keys) {
      if (best == null ||
          counts[raw]! > counts[best]! ||
          (counts[raw] == counts[best] && lastSeen[raw]! > lastSeen[best]!)) {
        best = raw;
      }
    }
    final matches = counts[best]!;
    return ConsensusResult(
      raw: best!,
      format: _entries[lastSeen[best]!].format,
      matches: matches,
      confidence: matches / window,
      reachedConsensus: false,
    );
  }

  void reset() => _entries.clear();
}
