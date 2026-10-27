import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// The release app has no INTERNET permission, so every font weight the UI
/// uses must load from the bundled assets (assets/google_fonts).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'every Inter and JetBrains Mono weight loads without the network',
    () async {
      final before = GoogleFonts.config.allowRuntimeFetching;
      GoogleFonts.config.allowRuntimeFetching = false;
      addTearDown(() => GoogleFonts.config.allowRuntimeFetching = before);

      final styles = [
        for (final weight in [
          FontWeight.w400,
          FontWeight.w500,
          FontWeight.w600,
          FontWeight.w700,
        ])
          GoogleFonts.inter(fontWeight: weight),
        for (final weight in [
          FontWeight.w400,
          FontWeight.w500,
          FontWeight.w600,
        ])
          GoogleFonts.jetBrainsMono(fontWeight: weight),
      ];

      // Throws (e.g. "font was not found in the application assets") when a
      // variant is missing and fetching is disabled.
      await expectLater(GoogleFonts.pendingFonts(styles), completes);
    },
  );
}
