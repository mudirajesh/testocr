import '../utils/gs1_constants.dart';

/// One parsed AI/value pair, in the order it appeared.
class Gs1Field {
  const Gs1Field({required this.ai, required this.name, required this.value});

  final String ai;
  final String name;
  final String value;

  @override
  String toString() => '($ai)$value';
}

/// One automatic character fix. Every change the parser makes is recorded so
/// nothing is silently "corrected".
class Gs1Correction {
  const Gs1Correction({
    required this.ai,
    required this.index,
    required this.from,
    required this.to,
    required this.reason,
  });

  final String ai;

  /// Zero-based position inside the field value.
  final int index;
  final String from;
  final String to;
  final String reason;

  @override
  String toString() => 'AI $ai [$index]: $from -> $to ($reason)';
}

/// Outcome of parsing one barcode. Immutable.
class Gs1ParseResult {
  Gs1ParseResult({
    required this.rawInput,
    required this.normalized,
    this.symbologyIdentifier,
    required List<Gs1Field> fields,
    required Map<String, String> byAi,
    required List<Gs1Correction> corrections,
    required List<String> warnings,
    required List<String> errors,
    required List<int> ambiguousBatchIndices,
    required this.isGs1,
  }) : fields = List.unmodifiable(fields),
       byAi = Map.unmodifiable(byAi),
       corrections = List.unmodifiable(corrections),
       warnings = List.unmodifiable(warnings),
       errors = List.unmodifiable(errors),
       ambiguousBatchIndices = List.unmodifiable(ambiguousBatchIndices);

  final String rawInput;

  /// After the symbology prefix was stripped and every separator shape was
  /// rewritten to [kSeparatorToken].
  final String normalized;

  /// The symbology prefix that was stripped, when there was one.
  final String? symbologyIdentifier;

  /// Every field, in order, duplicates included.
  final List<Gs1Field> fields;

  /// First occurrence of each AI.
  final Map<String, String> byAi;
  final List<Gs1Correction> corrections;
  final List<String> warnings;
  final List<String> errors;

  /// Positions of O/o/0 inside the batch number, for UI highlighting.
  final List<int> ambiguousBatchIndices;

  /// At least one known AI was parsed.
  final bool isGs1;

  bool get isValid => errors.isEmpty && isGs1;

  String? get gtin => byAi[kAiGtin];
  String? get batchNumber => byAi[kAiBatch];
  String? get expiryYymmdd => byAi[kAiExpiry];
  String? get serialNumber => byAi[kAiSerial];
  String? get productionDate => byAi[kAiProdDate];
  String? get count => byAi[kAiCount];

  bool get hasCorrections => corrections.isNotEmpty;
  bool get hasAmbiguousChars => ambiguousBatchIndices.isNotEmpty;

  @override
  String toString() =>
      'Gs1ParseResult(valid: $isValid, fields: $fields, '
      'errors: $errors, warnings: $warnings)';
}
