import 'package:flutter/painting.dart';

/// Positions of characters that look alike (O, o, 0) in a batch number.
List<int> ambiguousBatchPositions(String batch) => [
  for (var i = 0; i < batch.length; i++)
    if (batch[i] == 'O' || batch[i] == 'o' || batch[i] == '0') i,
];

/// One span per character, with look-alike characters on a coloured
/// background so they can be checked against the pack.
List<TextSpan> batchHighlightSpans(
  String batch,
  TextStyle style,
  Color highlight,
) {
  final ambiguous = ambiguousBatchPositions(batch).toSet();
  return [
    for (var i = 0; i < batch.length; i++)
      TextSpan(
        text: batch[i],
        style: ambiguous.contains(i)
            ? style.copyWith(backgroundColor: highlight)
            : style,
      ),
  ];
}
