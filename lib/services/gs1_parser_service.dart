import '../models/gs1_parse_result.dart';
import '../utils/gs1_constants.dart';
import '../utils/validators.dart';

/// Field as read off the wire, before cleaning.
class _RawField {
  _RawField(this.def, this.value);

  final AiDefinition def;
  String value;

  String get ai => def.ai;
}

/// Deterministic GS1 element-string parser.
///
/// Never throws: any internal failure comes back as a result carrying errors
/// and `isValid == false`. Every automatic character fix is recorded in
/// [Gs1ParseResult.corrections], so nothing is quietly rewritten.
class Gs1ParserService {
  const Gs1ParserService();

  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _allDigits = RegExp(r'^\d+$');
  static final RegExp _parenStart = RegExp(r'^\(\d{2,4}\)');
  static final RegExp _parenAi = RegExp(r'\((\d{2,4})\)');

  Gs1ParseResult parse(
    String raw, {
    String? barcodeFormat,
    bool preserveBatchSpaces = false,
  }) {
    try {
      return _parse(raw, barcodeFormat, preserveBatchSpaces);
    } catch (e) {
      return Gs1ParseResult(
        rawInput: raw,
        normalized: '',
        fields: const [],
        byAi: const {},
        corrections: const [],
        warnings: const [],
        errors: ['Parser failure: $e'],
        ambiguousBatchIndices: const [],
        isGs1: false,
      );
    }
  }

  Gs1ParseResult _parse(
    String raw,
    String? barcodeFormat,
    bool preserveBatchSpaces,
  ) {
    final warnings = <String>[];
    final errors = <String>[];
    final corrections = <Gs1Correction>[];
    final ambiguousBatchIndices = <int>[];

    // Step 0: nothing to parse.
    if (raw.trim().isEmpty) {
      return Gs1ParseResult(
        rawInput: raw,
        normalized: '',
        fields: const [],
        byAi: const {},
        corrections: corrections,
        warnings: warnings,
        errors: const ['Empty barcode'],
        ambiguousBatchIndices: ambiguousBatchIndices,
        isGs1: false,
      );
    }

    // Step 1: trim and strip one symbology identifier.
    var body = raw.trim();
    final symbology = _stripPrefix(body);
    if (symbology != null) body = body.substring(symbology.length);

    // Step 7: retail barcodes carry a bare GTIN; no AI walk applies.
    if ((barcodeFormat == kFormatEan13 || barcodeFormat == kFormatEan8) &&
        _allDigits.hasMatch(body)) {
      return _parseRetail(raw, body, symbology);
    }

    // Step 3 (detected early): in human-readable form "~" is a literal, not a
    // separator, so it must survive step 2.
    final isParenthesised = _parenStart.hasMatch(body);

    // Step 2: every separator shape becomes one token.
    final normalized = _normalizeSeparators(
      body,
      treatTildeAsSeparator: !isParenthesised,
    );

    final rawFields = isParenthesised
        ? _parseParenthesised(normalized, warnings)
        : _walk(normalized, warnings, errors);

    // Step 5: clean and correct.
    final fields = <Gs1Field>[];
    for (final f in rawFields) {
      final value = _cleanField(f, preserveBatchSpaces, corrections);
      if (f.ai == kAiBatch) {
        _collectAmbiguous(value, ambiguousBatchIndices, warnings);
      }
      fields.add(Gs1Field(ai: f.ai, name: f.def.name, value: value));
    }

    // First occurrence wins; later ones stay in [fields].
    final byAi = <String, String>{};
    final duplicatesWarned = <String>{};
    for (final f in fields) {
      if (byAi.containsKey(f.ai)) {
        if (duplicatesWarned.add(f.ai)) warnings.add('Duplicate AI ${f.ai}');
      } else {
        byAi[f.ai] = f.value;
      }
    }

    // Step 6: validate.
    _validate(fields, byAi, warnings, errors);

    // A Code 39 / ITF / Code 128 lot code is often just the batch itself.
    // Walking it as GS1 can invent AIs from digit pairs (e.g. "20" in
    // BN2024X981, or a leading "10"). If the payload looks like a lot and
    // is not a full GS1 element string, keep the whole string as the batch.
    if (_acceptsStandaloneBatch(barcodeFormat) && isStandaloneBatch(body)) {
      warnings.removeWhere(
        (w) =>
            w.startsWith('Unknown or unparsable data') ||
            w.startsWith('Unparsed data ignored') ||
            w.startsWith('Duplicate AI') ||
            w.startsWith('AI ') ||
            w.startsWith('No batch/lot number'),
      );
      errors.clear();
      corrections.clear();
      fields.clear();
      byAi.clear();
      ambiguousBatchIndices.clear();
      final batch = preserveBatchSpaces
          ? body
          : body.replaceAll(_whitespace, '');
      if (isValidBatch(batch)) {
        _collectAmbiguous(batch, ambiguousBatchIndices, warnings);
        final warning = batchCharWarning(batch);
        if (warning != null) warnings.add(warning);
        fields.add(
          Gs1Field(ai: kAiBatch, name: kAiTable[kAiBatch]!.name, value: batch),
        );
        byAi[kAiBatch] = batch;
      }
    }

    final isGs1 = fields.isNotEmpty;
    if (!isGs1) errors.add('Unrecognised barcode format');

    return Gs1ParseResult(
      rawInput: raw,
      normalized: normalized,
      symbologyIdentifier: symbology,
      fields: fields,
      byAi: byAi,
      corrections: corrections,
      warnings: warnings,
      errors: errors,
      ambiguousBatchIndices: ambiguousBatchIndices,
      isGs1: isGs1,
    );
  }

  // ---------------------------------------------------------------- step 1

  /// Retail EAN/UPC never encodes a lot. Every other symbology may.
  bool _acceptsStandaloneBatch(String? barcodeFormat) {
    if (barcodeFormat == kFormatEan13 || barcodeFormat == kFormatEan8) {
      return false;
    }
    if (barcodeFormat == 'ean13' || barcodeFormat == 'ean8') return false;
    return true;
  }

  String? _stripPrefix(String s) {
    for (final prefix in kSymbologyIdentifiers) {
      if (s.startsWith(prefix)) return prefix;
    }
    return null;
  }

  // ---------------------------------------------------------------- step 2

  String _normalizeSeparators(String s, {required bool treatTildeAsSeparator}) {
    var out = s;
    for (final rep in kSeparatorRepresentations) {
      if (rep == '~' && !treatTildeAsSeparator) continue;
      out = out.replaceAll(rep, kSeparatorToken);
    }
    return out;
  }

  // ---------------------------------------------------------------- step 3

  /// Human-readable form, e.g. "(01)08901234567890(17)261231". The parentheses
  /// delimit the values, so a variable-length value simply runs to the next "(".
  List<_RawField> _parseParenthesised(String s, List<String> warnings) {
    final out = <_RawField>[];
    final matches = _parenAi.allMatches(s).toList();
    for (var n = 0; n < matches.length; n++) {
      final m = matches[n];
      final ai = m.group(1)!;
      final end = n + 1 < matches.length ? matches[n + 1].start : s.length;
      final value = s.substring(m.end, end).replaceAll(kSeparatorToken, '');
      final def = kAiTable[ai];
      if (def == null) {
        warnings.add('Unknown AI ($ai)');
        continue;
      }
      out.add(_RawField(def, value));
    }
    return out;
  }

  // ---------------------------------------------------------------- step 4

  /// Walks the normalized string, matching AI codes and reading their values.
  ///
  /// FNC1 handling is the crux. A fixed-length AI needs no terminator, so its
  /// value is exactly N characters; hitting a separator early means the data
  /// was truncated. A variable-length AI runs to the next separator, and when
  /// no separator arrives but the value overruns the AI's maximum, the
  /// scanner almost certainly dropped the FNC1: we take exactly maxLength
  /// characters, warn, and resume parsing the remainder as the next AI.
  List<_RawField> _walk(String s, List<String> warnings, List<String> errors) {
    final out = <_RawField>[];
    final skipped = StringBuffer();
    var i = 0;
    var inUnparsedRun = false;

    while (i < s.length) {
      final ch = s[i];
      if (ch == kSeparatorToken || _isSpace(ch)) {
        i++;
        continue;
      }

      final ai = _matchAi(s, i);
      if (ai == null) {
        // Unknown data: warn once per run, then advance a character at a time
        // so a later AI in the same string can still be recovered.
        if (!inUnparsedRun) {
          warnings.add('Unknown or unparsable data at position $i');
          inUnparsedRun = true;
        }
        skipped.write(ch);
        i++;
        continue;
      }
      inUnparsedRun = false;

      final def = kAiTable[ai]!;
      i += ai.length;

      final fixed = def.fixedLength;
      if (fixed != null) {
        final buffer = StringBuffer();
        var taken = 0;
        while (i < s.length && taken < fixed) {
          final c = s[i];
          if (c == kSeparatorToken) break; // early separator = truncated
          i++;
          if (_isSpace(c)) continue; // whitespace never counts toward N
          buffer.write(c);
          taken++;
        }
        if (taken < fixed) errors.add('AI $ai: truncated');
        out.add(_RawField(def, buffer.toString()));
        continue;
      }

      // Variable length: run to the next separator, or to the end.
      var j = i;
      var stoppedAtSeparator = false;
      while (j < s.length) {
        if (s[j] == kSeparatorToken) {
          stoppedAtSeparator = true;
          break;
        }
        j++;
      }
      final value = s.substring(i, j);
      if (!stoppedAtSeparator && value.length > def.maxLength) {
        // Probable missing FNC1: split at the maximum and keep parsing.
        out.add(_RawField(def, value.substring(0, def.maxLength)));
        warnings.add('AI $ai: possible missing FNC1 separator');
        i += def.maxLength;
        continue;
      }
      // Separator-terminated but over-long: keep it whole and let step 6
      // report it rather than guessing where the real boundary was.
      out.add(_RawField(def, value));
      i = j;
    }

    if (skipped.isNotEmpty) {
      warnings.add('Unparsed data ignored: $skipped');
    }
    return out;
  }

  /// Longest-prefix AI match, trying 2 then 3 then 4 digits, so 240 or 710 is
  /// not mistaken for a 2-digit AI (and "24" alone is not in the table).
  String? _matchAi(String s, int i) {
    for (final len in const [2, 3, 4]) {
      if (i + len > s.length) break;
      final candidate = s.substring(i, i + len);
      if (!_allDigits.hasMatch(candidate)) break;
      if (kAiTable.containsKey(candidate)) return candidate;
    }
    return null;
  }

  // ---------------------------------------------------------------- step 5

  String _cleanField(
    _RawField f,
    bool preserveBatchSpaces,
    List<Gs1Correction> corrections,
  ) {
    var v = f.value.trim();

    if (f.def.isNumeric || f.ai == kAiSerial) {
      v = v.replaceAll(_whitespace, '');
    } else if (f.ai == kAiBatch && !preserveBatchSpaces) {
      v = v.replaceAll(_whitespace, '');
    }

    // Character fixes apply to numeric fields only. Batch and serial are
    // alphanumeric: an "O" there may be a real character, so it is left alone.
    if (!f.def.isNumeric) return v;

    v = _substitute(
      f.ai,
      v,
      kAlwaysSubstitutions,
      corrections,
      'Ambiguous character in numeric field',
    );

    // S/B are riskier, so they are applied only to fields we can verify and
    // only when the substitution is what makes the field valid.
    if (_canVerify(f.ai) && !_passes(f.ai, v)) {
      final candidate = _applyMap(v, kConditionalSubstitutions);
      if (candidate != v && _passes(f.ai, candidate)) {
        v = _substitute(
          f.ai,
          v,
          kConditionalSubstitutions,
          corrections,
          'Substitution validated by check digit or date',
        );
      }
    }
    return v;
  }

  bool _canVerify(String ai) => ai == kAiGtin || kDateAis.contains(ai);

  bool _passes(String ai, String v) {
    if (ai == kAiGtin) return isValidGtinCheckDigit(v);
    if (kDateAis.contains(ai)) return isValidGs1Date(v);
    return false;
  }

  String _applyMap(String v, Map<String, String> map) {
    final sb = StringBuffer();
    for (final c in v.split('')) {
      sb.write(map[c] ?? c);
    }
    return sb.toString();
  }

  String _substitute(
    String ai,
    String v,
    Map<String, String> map,
    List<Gs1Correction> corrections,
    String reason,
  ) {
    final sb = StringBuffer();
    for (var i = 0; i < v.length; i++) {
      final c = v[i];
      final to = map[c];
      if (to == null) {
        sb.write(c);
        continue;
      }
      sb.write(to);
      corrections.add(
        Gs1Correction(ai: ai, index: i, from: c, to: to, reason: reason),
      );
    }
    return sb.toString();
  }

  /// The batch itself is never rewritten; the confusable positions are only
  /// reported so the UI can ask a human.
  void _collectAmbiguous(
    String batch,
    List<int> indices,
    List<String> warnings,
  ) {
    var found = false;
    for (var i = 0; i < batch.length; i++) {
      final c = batch[i];
      if (c == 'O' || c == 'o' || c == '0') {
        indices.add(i);
        found = true;
      }
    }
    if (found) {
      warnings.add('Batch contains characters that can be confused (O/0)');
    }
  }

  // ---------------------------------------------------------------- step 6

  void _validate(
    List<Gs1Field> fields,
    Map<String, String> byAi,
    List<String> warnings,
    List<String> errors,
  ) {
    for (final f in fields) {
      final def = kAiTable[f.ai]!;
      final v = f.value;

      if (f.ai == kAiGtin) {
        if (v.length != 14 || !isDigitsOnly(v)) {
          errors.add('GTIN must be 14 digits');
        } else if (!isValidGtinCheckDigit(v)) {
          errors.add('GTIN check digit invalid');
        }
        continue;
      }

      if (kDateAis.contains(f.ai)) {
        if (!isValidGs1Date(v)) errors.add('AI ${f.ai}: invalid date');
        continue;
      }

      if (f.ai == kAiBatch) {
        if (!isValidBatch(v)) {
          errors.add('AI ${f.ai}: invalid batch/lot number');
        }
        final warning = batchCharWarning(v);
        if (warning != null) warnings.add(warning);
        continue;
      }

      if (f.ai == kAiSerial) {
        if (!isValidSerial(v)) errors.add('AI ${f.ai}: invalid serial number');
        continue;
      }

      if (def.isNumeric && !isDigitsOnly(v)) {
        errors.add('AI ${f.ai}: must contain digits only');
        continue;
      }
      if (v.length > def.maxLength) {
        errors.add('AI ${f.ai}: value too long');
      }
    }

    if (byAi.containsKey(kAiGtin) && !byAi.containsKey(kAiBatch)) {
      warnings.add('No batch/lot number in this barcode');
    }
  }

  // ---------------------------------------------------------------- step 7

  /// EAN-13/EAN-8 carry a bare GTIN: left-pad to 14 and verify.
  Gs1ParseResult _parseRetail(String raw, String digits, String? symbology) {
    final errors = <String>[];
    final padded = digits.padLeft(14, '0');

    if (padded.length != 14) {
      errors.add('GTIN must be 14 digits');
    } else if (!isValidGtinCheckDigit(padded)) {
      errors.add('GTIN check digit invalid');
    }

    return Gs1ParseResult(
      rawInput: raw,
      normalized: digits,
      symbologyIdentifier: symbology,
      fields: [
        Gs1Field(ai: kAiGtin, name: kAiTable[kAiGtin]!.name, value: padded),
      ],
      byAi: {kAiGtin: padded},
      corrections: const [],
      warnings: const ['Retail barcode: no batch/lot data'],
      errors: errors,
      ambiguousBatchIndices: const [],
      isGs1: true,
    );
  }

  bool _isSpace(String c) => c.trim().isEmpty;
}
