import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/detected_barcode.dart';
import 'package:gs1scan/services/consensus_buffer.dart';

void main() {
  group('ConsensusBuffer', () {
    test('3 identical detections reach consensus at confidence 0.6', () {
      final b = ConsensusBuffer();
      expect(b.add('A', 'code128'), isNull);
      expect(b.add('A', 'code128'), isNull);
      final r = b.add('A', 'code128')!;
      expect(r.reachedConsensus, isTrue);
      expect(r.raw, 'A');
      expect(r.format, 'code128');
      expect(r.matches, 3);
      expect(r.confidence, closeTo(0.6, 1e-9));
    });

    test('5 identical detections give confidence 1.0', () {
      final b = ConsensusBuffer();
      ConsensusResult? last;
      for (var i = 0; i < 5; i++) {
        last = b.add('A', 'dataMatrix');
      }
      expect(last!.matches, 5);
      expect(last.confidence, closeTo(1.0, 1e-9));
    });

    test('2 identical plus 3 distinct values is no consensus', () {
      final b = ConsensusBuffer();
      expect(b.add('A', 'x'), isNull);
      expect(b.add('A', 'x'), isNull);
      expect(b.add('B', 'x'), isNull);
      expect(b.add('C', 'x'), isNull);
      expect(b.add('D', 'x'), isNull);
    });

    test('a misread frame in the middle still reaches consensus on A', () {
      final b = ConsensusBuffer();
      expect(b.add('A', 'x'), isNull);
      expect(b.add('A', 'x'), isNull);
      expect(b.add('X', 'x'), isNull);
      final r = b.add('A', 'x')!;
      expect(r.raw, 'A');
      expect(r.matches, 3);
    });

    test('rolling window: old values stop counting', () {
      final b = ConsensusBuffer();
      b.add('A', 'x');
      b.add('A', 'x');
      for (final v in ['B', 'C', 'D', 'E', 'F']) {
        b.add(v, 'x');
      }
      expect(b.length, 5);
      // The two original As were pushed out, so one new A cannot make 3.
      expect(b.add('A', 'x'), isNull);
      expect(b.bestSoFar()!.matches, 1);
    });

    test('bestSoFar returns the most common value', () {
      final b = ConsensusBuffer();
      b
        ..add('A', 'x')
        ..add('B', 'x')
        ..add('B', 'x');
      final best = b.bestSoFar()!;
      expect(best.raw, 'B');
      expect(best.matches, 2);
      expect(best.confidence, closeTo(0.4, 1e-9));
      expect(best.reachedConsensus, isFalse);
    });

    test('bestSoFar breaks ties by the most recent value', () {
      final b = ConsensusBuffer();
      b
        ..add('A', 'x')
        ..add('B', 'x')
        ..add('A', 'x')
        ..add('B', 'x');
      expect(b.bestSoFar()!.raw, 'B');
    });

    test('bestSoFar is null when empty', () {
      expect(ConsensusBuffer().bestSoFar(), isNull);
    });

    test('reset empties the buffer', () {
      final b = ConsensusBuffer()
        ..add('A', 'x')
        ..add('A', 'x');
      expect(b.isEmpty, isFalse);
      b.reset();
      expect(b.isEmpty, isTrue);
      expect(b.length, 0);
      expect(b.bestSoFar(), isNull);
    });

    test('matching is exact: O and 0 are different values', () {
      final b = ConsensusBuffer();
      b.add('BN2024X981', 'x');
      b.add('BN2O24X981', 'x');
      expect(b.add('BN2024X981', 'x'), isNull);
      expect(b.add('bn2024x981', 'x'), isNull);
      expect(b.add('BN2024X981 ', 'x'), isNull);
    });
  });

  group('pickCentermost', () {
    DetectedBarcode at(String v, double x, double y) =>
        DetectedBarcode(rawValue: v, format: 'code128', centerX: x, centerY: y);

    test('picks the barcode nearest the centre', () {
      final picked = pickCentermost([
        at('corner', 0.1, 0.1),
        at('near', 0.55, 0.45),
        at('edge', 0.9, 0.5),
      ]);
      expect(picked!.rawValue, 'near');
    });

    test('returns null for an empty list', () {
      expect(pickCentermost(const []), isNull);
    });

    test('a single item is returned', () {
      expect(pickCentermost([at('only', 0.9, 0.9)])!.rawValue, 'only');
    });
  });
}
