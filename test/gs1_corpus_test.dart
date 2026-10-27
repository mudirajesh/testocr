import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/services/gs1_parser_service.dart';
import 'package:gs1scan/utils/validators.dart';

/// Regression corpus for the GS1 parser. The labelled strings live in
/// test/fixtures/gs1_corpus.json (see the notes at the top of that file for
/// how to add strings captured from real packs).
void main() {
  const parser = Gs1ParserService();

  final doc = jsonDecode(
    File('test/fixtures/gs1_corpus.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();

  final outcomes = <String, bool>{};

  test('the corpus is large enough and every case has a unique name', () {
    expect(cases.length, greaterThanOrEqualTo(40));
    final names = cases.map((c) => c['name']).toSet();
    expect(names.length, cases.length);
  });

  test('every GTIN marked valid in the corpus has a correct check digit', () {
    for (final c in cases) {
      final expected = c['expected'] as Map<String, dynamic>;
      final gtin = expected['gtin'] as String?;
      if (c['valid'] == true && gtin != null && gtin.length == 14) {
        expect(
          isValidGtinCheckDigit(gtin),
          isTrue,
          reason: 'corpus GTIN for "${c['name']}" is not self-consistent',
        );
      }
    }
  });

  group('corpus', () {
    for (final c in cases) {
      final name = c['name'] as String;
      test(name, () {
        var passed = false;
        addTearDown(() => outcomes[name] = passed);

        final result = parser.parse(
          c['raw'] as String,
          barcodeFormat: c['barcodeFormat'] as String?,
          preserveBatchSpaces: c['preserveBatchSpaces'] == true,
        );

        final expected = c['expected'] as Map<String, dynamic>;
        expect(result.gtin, expected['gtin'], reason: 'gtin');
        expect(result.batchNumber, expected['batch'], reason: 'batch');
        expect(result.expiryYymmdd, expected['expiry'], reason: 'expiry');
        expect(result.serialNumber, expected['serial'], reason: 'serial');
        if (expected.containsKey('productionDate')) {
          expect(result.productionDate, expected['productionDate']);
        }
        if (expected.containsKey('count')) {
          expect(result.count, expected['count']);
        }

        expect(result.isValid, c['valid'], reason: 'isValid');
        expect(result.rawInput, c['raw'], reason: 'rawInput is preserved');

        for (final fragment in (c['warnings'] as List? ?? const [])) {
          expect(
            result.warnings.any((w) => w.contains(fragment as String)),
            isTrue,
            reason: 'warning containing "$fragment" in ${result.warnings}',
          );
        }
        for (final fragment in (c['errors'] as List? ?? const [])) {
          expect(
            result.errors.any((e) => e.contains(fragment as String)),
            isTrue,
            reason: 'error containing "$fragment" in ${result.errors}',
          );
        }
        if (c.containsKey('ambiguousBatchIndices')) {
          expect(
            result.ambiguousBatchIndices,
            (c['ambiguousBatchIndices'] as List).cast<int>(),
          );
        }
        if (c.containsKey('corrections')) {
          expect(
            result.corrections.length,
            (c['corrections'] as List).length,
            reason: 'recorded corrections: ${result.corrections}',
          );
        }
        passed = true;
      });
    }
  });

  tearDownAll(() {
    final passed = outcomes.values.where((ok) => ok).length;
    final buffer = StringBuffer()
      ..writeln()
      ..writeln('GS1 corpus summary')
      ..writeln('------------------------------------------------------------');
    outcomes.forEach((name, ok) {
      buffer.writeln('${ok ? 'PASS' : 'FAIL'}  $name');
    });
    buffer
      ..writeln('------------------------------------------------------------')
      ..writeln('$passed / ${cases.length} cases passed');
    // ignore: avoid_print
    print(buffer);
  });
}
