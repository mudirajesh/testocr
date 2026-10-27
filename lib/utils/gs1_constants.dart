// GS1 Application Identifier (AI) table and the separator/prefix shapes a
// real-world scanner can emit. Pure data, no Flutter imports.

/// One AI in the table.
class AiDefinition {
  const AiDefinition(
    this.ai,
    this.name, {
    this.fixedLength,
    required this.maxLength,
    required this.isNumeric,
  });

  final String ai;
  final String name;

  /// Non-null when the value has a fixed length (no FNC1 terminator needed).
  final int? fixedLength;
  final int maxLength;

  /// True when the value is digits only, so character fixes may be applied.
  final bool isNumeric;

  bool get isFixedLength => fixedLength != null;
}

// Common AIs.
const kAiSscc = '00';
const kAiGtin = '01';
const kAiContainedGtin = '02';
const kAiBatch = '10';
const kAiProdDate = '11';
const kAiPackagingDate = '13';
const kAiBestBefore = '15';
const kAiExpiry = '17';
const kAiVariant = '20';
const kAiSerial = '21';
const kAiCount = '30';

/// Date-bearing AIs, all YYMMDD.
const kDateAis = <String>[
  kAiProdDate,
  kAiPackagingDate,
  kAiBestBefore,
  kAiExpiry,
];

const Map<String, AiDefinition> kAiTable = <String, AiDefinition>{
  kAiSscc: AiDefinition(
    kAiSscc,
    'SSCC',
    fixedLength: 18,
    maxLength: 18,
    isNumeric: true,
  ),
  kAiGtin: AiDefinition(
    kAiGtin,
    'GTIN',
    fixedLength: 14,
    maxLength: 14,
    isNumeric: true,
  ),
  kAiContainedGtin: AiDefinition(
    kAiContainedGtin,
    'Contained GTIN',
    fixedLength: 14,
    maxLength: 14,
    isNumeric: true,
  ),
  kAiBatch: AiDefinition(
    kAiBatch,
    'Batch/Lot',
    maxLength: 20,
    isNumeric: false,
  ),
  kAiProdDate: AiDefinition(
    kAiProdDate,
    'Production date',
    fixedLength: 6,
    maxLength: 6,
    isNumeric: true,
  ),
  kAiPackagingDate: AiDefinition(
    kAiPackagingDate,
    'Packaging date',
    fixedLength: 6,
    maxLength: 6,
    isNumeric: true,
  ),
  kAiBestBefore: AiDefinition(
    kAiBestBefore,
    'Best before',
    fixedLength: 6,
    maxLength: 6,
    isNumeric: true,
  ),
  kAiExpiry: AiDefinition(
    kAiExpiry,
    'Expiry date',
    fixedLength: 6,
    maxLength: 6,
    isNumeric: true,
  ),
  kAiVariant: AiDefinition(
    kAiVariant,
    'Variant',
    fixedLength: 2,
    maxLength: 2,
    isNumeric: true,
  ),
  kAiSerial: AiDefinition(
    kAiSerial,
    'Serial number',
    maxLength: 20,
    isNumeric: false,
  ),
  kAiCount: AiDefinition(
    kAiCount,
    'Count of items',
    maxLength: 8,
    isNumeric: true,
  ),
  '37': AiDefinition('37', 'Count of units', maxLength: 8, isNumeric: true),
  '240': AiDefinition(
    '240',
    'Additional product ID',
    maxLength: 30,
    isNumeric: false,
  ),
  '241': AiDefinition(
    '241',
    'Customer part number',
    maxLength: 30,
    isNumeric: false,
  ),
  '710': AiDefinition(
    '710',
    'NHRN Germany (PZN)',
    maxLength: 20,
    isNumeric: false,
  ),
  '711': AiDefinition(
    '711',
    'NHRN France (CIP)',
    maxLength: 20,
    isNumeric: false,
  ),
  '712': AiDefinition(
    '712',
    'NHRN Spain (CN)',
    maxLength: 20,
    isNumeric: false,
  ),
  '713': AiDefinition(
    '713',
    'NHRN Brazil (DRN)',
    maxLength: 20,
    isNumeric: false,
  ),
  '714': AiDefinition(
    '714',
    'NHRN Portugal (AIM)',
    maxLength: 20,
    isNumeric: false,
  ),
  '715': AiDefinition(
    '715',
    'NHRN United States (NDC)',
    maxLength: 20,
    isNumeric: false,
  ),
};

/// Every text shape a scanner may use for FNC1/GS. All are rewritten to
/// [kSeparatorToken] before parsing.
const kSeparatorRepresentations = <String>[
  r'\x1D', // 4-character literal, emitted by some keyboard-wedge scanners
  '<GS>',
  '[GS]',
  '\u001D', // the real GS control character (ASCII 29)
  '~', // common "show me the separator" substitute
];

/// Internal separator the parser walks on.
const kSeparatorToken = '|';

/// Symbology identifier prefixes, stripped before parsing.
const kSymbologyIdentifiers = <String>[']C1', ']d2', ']e0', ']Q3', ']E0'];

/// Retail barcode formats that carry a bare GTIN and no AIs.
const kFormatEan13 = 'EAN-13';
const kFormatEan8 = 'EAN-8';

/// Always-applied letter to digit fixes inside numeric fields.
const kAlwaysSubstitutions = <String, String>{
  'O': '0',
  'o': '0',
  'I': '1',
  'l': '1',
};

/// Riskier fixes, applied only when they make a field validate.
const kConditionalSubstitutions = <String, String>{'S': '5', 'B': '8'};
