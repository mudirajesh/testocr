import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:gs1scan/widgets/db_corruption_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/spy_db.dart';

void main() {
  late SpyDb db;

  setUp(() => db = SpyDb());
  tearDown(() => db.close());

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDbCorruptionDialogIfNeeded(context, db),
                child: const Text('check'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows once when the flag is set and clears it after OK', (
    tester,
  ) async {
    db.wasResetDueToCorruption = true;
    await pumpHost(tester);

    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();

    expect(find.text('Database reset'), findsOneWidget);
    expect(
      find.text(
        'The database was reset due to corruption. Previous records are lost.',
      ),
      findsOneWidget,
    );
    expect(db.wasResetDueToCorruption, isTrue); // not cleared until OK

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Database reset'), findsNothing);
    expect(db.wasResetDueToCorruption, isFalse);

    // Acknowledged: never shown again this session.
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    expect(find.text('Database reset'), findsNothing);
  });

  testWidgets('cannot be dismissed outside the OK button', (tester) async {
    db.wasResetDueToCorruption = true;
    await pumpHost(tester);
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Database reset'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Database reset'), findsOneWidget);
    expect(db.wasResetDueToCorruption, isTrue);
  });

  testWidgets('does nothing when the database is healthy', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    expect(find.text('Database reset'), findsNothing);
  });

  group('DatabaseService corruption handling', () {
    late Directory dir;

    setUp(() async {
      sqfliteFfiInit();
      dir = await Directory.systemTemp.createTemp('gs1_corrupt');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('an unreadable file is replaced and flagged', () async {
      final path = '${dir.path}/broken.db';
      await File(path).writeAsBytes(List<int>.filled(4096, 0x41));

      final service = DatabaseService.forTesting(
        factory: databaseFactoryFfi,
        path: path,
      );
      addTearDown(service.close);

      expect(await service.count(), 0); // opens a fresh, working database
      expect(service.wasResetDueToCorruption, isTrue);

      service.acknowledgeCorruptionReset();
      expect(service.wasResetDueToCorruption, isFalse);
    });

    test('a healthy file is not flagged', () async {
      final service = DatabaseService.forTesting(
        factory: databaseFactoryFfi,
        path: '${dir.path}/ok.db',
      );
      addTearDown(service.close);

      expect(await service.count(), 0);
      expect(service.wasResetDueToCorruption, isFalse);
    });
  });
}
