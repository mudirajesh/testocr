// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/medicine_item.dart';
import 'medicine_lookup_service.dart';

class OcrResult {
  const OcrResult({
    required this.rawText,
    this.batchNumber,
    this.expiryDate,
    this.medicineName,
    this.strength,
    this.matchedMedicine,
  });

  final String rawText;
  final String? batchNumber;
  final String? expiryDate;
  final String? medicineName;
  final String? strength;
  final MedicineItem? matchedMedicine;

  bool get hasBatch => batchNumber != null && batchNumber!.isNotEmpty;
  bool get hasMedicine =>
      (medicineName != null && medicineName!.isNotEmpty) ||
      matchedMedicine != null;
}

/// Fallback OCR service using google_mlkit_text_recognition.
/// Extracts printed text from images to recover Batch Number, Expiry,
/// and Medicine Name & Strength when the barcode is absent or unreadable.
class OcrService {
  const OcrService({MedicineLookupService lookup = const MedicineLookupService()})
      : _lookup = lookup;

  final MedicineLookupService _lookup;

  static final _batchPattern = RegExp(
    r'(?:BATCH(?:\s*NO|\s*#)?|B\.?\s*NO\.?|LOT(?:\s*NO|\s*#)?|B\.?\s*N\.?|BN)[:\s\-#]*([A-Za-z0-9\-/]{3,20})',
    caseSensitive: false,
  );

  static final _expiryPattern = RegExp(
    r'(?:EXP(?:\.?\s*DATE)?|EXPIRY|USE\s*BEFORE)[:\s\-]*([0-9]{1,2}[/-][0-9]{2,4})',
    caseSensitive: false,
  );

  static final _strengthPattern = RegExp(
    r'\b(\d+(?:\.\d+)?\s*(?:mg|g|mcg|ml|IU|%))\b',
    caseSensitive: false,
  );

  static final _batchLabelOnly = RegExp(
    r'^(?:BATCH(?:\s*NO|\s*#)?|LOT(?:\s*NO|\s*#)?|B\.?\s*N\.?|BN)[:\s\-#]*$',
    caseSensitive: false,
  );

  static String? _firstGroup(RegExp pattern, String text) {
    final match = pattern.firstMatch(text);
    if (match == null || match.groupCount < 1) return null;
    final val = match.group(1)?.trim();
    if (val == null || val.isEmpty) return null;
    return val;
  }

  static String? _firstGroupIn(List<String> lines, RegExp pattern) {
    for (final text in lines) {
      final val = _firstGroup(pattern, text);
      if (val != null) return val;
    }
    return null;
  }

  /// Label and value on the same line, or the value on the following line.
  static String? _batchFromLines(List<String> lines) {
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i];
      final val = _firstGroup(_batchPattern, text);
      if (val != null && val.length >= 3) return val;
      if (_batchLabelOnly.hasMatch(text) && i + 1 < lines.length) {
        final next = lines[i + 1].replaceAll(RegExp(r'[^A-Za-z0-9.\-/]'), '');
        if (next.length >= 3 && next.length <= 20) return next;
      }
    }
    return null;
  }

  /// Performs text recognition on an image file.
  Future<OcrResult> processImage(String imagePath) async {
    if (!File(imagePath).existsSync()) {
      return const OcrResult(rawText: '');
    }

    final inputImage = InputImage.fromFilePath(imagePath);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final recognized = await recognizer.processImage(inputImage);
      final fullText = recognized.text;
      debugPrint('OCR recognized text:\n$fullText');

      String? batchNumber;
      String? expiryDate;
      String? strength;

      batchNumber = _firstGroup(_batchPattern, fullText);
      expiryDate = _firstGroup(_expiryPattern, fullText);
      strength = _firstGroup(_strengthPattern, fullText);

      final lines = <String>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          lines.add(line.text.trim());
        }
      }
      batchNumber ??= _batchFromLines(lines);
      expiryDate ??= _firstGroupIn(lines, _expiryPattern);
      strength ??= _firstGroupIn(lines, _strengthPattern);

      // 4. Medicine lookup from full recognized text
      final matchedMedicine = _lookup.lookup(text: fullText);

      return OcrResult(
        rawText: fullText,
        batchNumber: batchNumber,
        expiryDate: expiryDate,
        medicineName: matchedMedicine?.name,
        strength: strength ?? matchedMedicine?.strength,
        matchedMedicine: matchedMedicine,
      );
    } catch (e) {
      debugPrint('OCR processing failed: $e');
      return const OcrResult(rawText: '');
    } finally {
      await recognizer.close();
    }
  }
}
