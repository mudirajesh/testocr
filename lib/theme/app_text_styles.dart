import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Typography tokens: Inter for headlines/body, JetBrains Mono for labels.
abstract final class AppTextStyles {
  static TextStyle get headline =>
      GoogleFonts.inter(fontWeight: FontWeight.w700);

  static TextStyle get body => GoogleFonts.inter(fontWeight: FontWeight.w400);

  static TextStyle get label =>
      GoogleFonts.jetBrainsMono(fontWeight: FontWeight.w500);
}
