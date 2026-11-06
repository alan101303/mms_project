import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mms_project/evaluation_log.dart';
import 'package:mms_project/main.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ttsChannel = MethodChannel('flutter_tts');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(ttsChannel, (_) async => 1);
  });

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(ttsChannel, null)
      ..setMockMethodCallHandler(pathChannel, null);
  });

  Future<KitchenController> pumpApp(
    WidgetTester tester, {
    FakeMicPermission? permission,
    EvaluationStorage? storage,
  }) async {
    final kitchen = KitchenController(
      sounds: FakeSoundEffects(),
      permission: permission,
      storage: storage ?? MemoryEvaluationStorage(),
    );
    // Asset loading is real I/O, which the test's fake clock can't drive.
    await tester.runAsync(kitchen.loadRecipes);
    if (permission != null) await kitchen.checkMicPermission();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => kitchen,
        child: const KitchenApp(),
      ),
    );
    await tester.pumpAndSettle();
    return kitchen;
  }

  Future<KitchenController> openCookingPage(WidgetTester tester) async {
    final kitchen = await pumpApp(tester);
    await tester.tap(find.text('Cremige Tomatenpasta'));
    await tester.pumpAndSettle();
    return kitchen;
  }

  group('permission screen', () {
    testWidgets('explains the mic and continues once it is allowed', (
      tester,
    ) async {
      await pumpApp(
        tester,
        permission: FakeMicPermission(PermissionStatus.denied),
      );
      expect(find.text('Sprachsteuerung erlauben'), findsOneWidget);
      expect(find.text('Was kochen wir?'), findsNothing);

      await tester.tap(find.text('Mikrofon freigeben'));
      await tester.pumpAndSettle();
      expect(find.text('Was kochen wir?'), findsOneWidget);
    });

    testWidgets('offers the settings after a permanent denial', (
      tester,
    ) async {
      final permission = FakeMicPermission(
        PermissionStatus.denied,
        afterRequest: PermissionStatus.permanentlyDenied,
      );
      await pumpApp(tester, permission: permission);

      await tester.tap(find.text('Mikrofon freigeben'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Einstellungen öffnen'));
      expect(permission.settingsOpened, isTrue);
    });

    testWidgets('can be skipped to use touch only', (tester) async {
      await pumpApp(
        tester,
        permission: FakeMicPermission(PermissionStatus.denied),
      );
      await tester.tap(find.text('Ohne Sprache fortfahren'));
      await tester.pumpAndSettle();
      expect(find.text('Was kochen wir?'), findsOneWidget);
    });

    testWidgets('is skipped when the mic is already allowed', (tester) async {
      await pumpApp(
        tester,
        permission: FakeMicPermission(PermissionStatus.granted),
      );
      expect(find.text('Was kochen wir?'), findsOneWidget);
    });
  });

  group('timer controls', () {
    testWidgets('pause and stop by touch', (tester) async {
      final kitchen = await openCookingPage(tester);
      await kitchen.startTimer(const Duration(minutes: 5));
      await tester.pump();

      await tester.tap(find.byTooltip('Timer pausieren'));
      await tester.pump(const Duration(seconds: 5));
      expect(kitchen.timerPaused, isTrue);
      expect(kitchen.timerSeconds, 300);

      await tester.tap(find.byTooltip('Timer fortsetzen'));
      await tester.pump(const Duration(seconds: 5));
      expect(kitchen.timerSeconds, 295);

      await tester.tap(find.byTooltip('Timer stoppen'));
      await tester.pump(const Duration(seconds: 1));
      expect(kitchen.timerSeconds, 0);
    });

    testWidgets('a timer paused by voice stays paused while cooking', (
      tester,
    ) async {
      final kitchen = KitchenController(sounds: FakeSoundEffects());
      await tester.runAsync(kitchen.loadRecipes);
      kitchen.openRecipe(0);
      await kitchen.startTimer(const Duration(minutes: 5));

      await kitchen.handleCommand('timer pausieren', 0.9);
      await kitchen.handleCommand('weiter', 0.9);
      await tester.pump(const Duration(seconds: 5));
      expect(kitchen.timerPaused, isTrue);
      expect(kitchen.timerSeconds, 300);

      await kitchen.handleCommand('timer fortsetzen', 0.9);
      await tester.pump(const Duration(seconds: 5));
      expect(kitchen.timerSeconds, 295);

      await kitchen.cancelTimer();
      await tester.pump(const Duration(seconds: 1));
      kitchen.dispose();
    });
  });

  group('cooking page', () {
    testWidgets('a button turns green briefly when used by voice', (
      tester,
    ) async {
      final kitchen = await openCookingPage(tester);
      await kitchen.handleCommand('weiter', 0.9);
      await tester.pump();
      expect(kitchen.highlightedControl, CookingControl.pause);

      await kitchen.handleCommand('weiter', 0.9);
      await tester.pump();
      expect(kitchen.highlightedControl, CookingControl.next);
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.arrow_forward_rounded),
      );
      expect(
        button.style?.backgroundColor?.resolve({}),
        const Color(0xFF2E9D57),
      );

      await tester.pump(const Duration(seconds: 1));
      expect(kitchen.highlightedControl, isNull);
    });

    testWidgets('ingredients close by touch and by voice', (tester) async {
      final kitchen = await openCookingPage(tester);

      await tester.tap(find.byTooltip('Zutaten anzeigen'));
      await tester.pump();
      expect(kitchen.ingredientsVisible, isTrue);
      expect(find.text('·  200 g Pasta'), findsOneWidget);

      await tester.tap(find.byTooltip('Zutaten schließen'));
      await tester.pump();
      expect(find.text('·  200 g Pasta'), findsNothing);
      expect(find.byTooltip('Zutaten anzeigen'), findsOneWidget);

      kitchen.showIngredients();
      await kitchen.handleCommand('zutaten schließen', 0.9);
      await tester.pump(const Duration(seconds: 1));
      expect(kitchen.ingredientsVisible, isFalse);
    });

    testWidgets('help opens from the cooking page and explains the mic', (
      tester,
    ) async {
      await openCookingPage(tester);
      await tester.tap(find.byTooltip('Hilfe und Sprachbefehle').last);
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Mikrofon-Status'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Grünes Mikrofon: Die App hört zu.'), findsOneWidget);
    });
  });

  group('evaluation', () {
    VoiceLogEntry entry(VoiceOutcome outcome, int? ms, {bool? correct}) =>
        VoiceLogEntry(
          time: DateTime(2026, 11, 24, 10),
          text: 'weiter',
          confidence: 0.9,
          outcome: outcome,
          detail: 'Weiter',
          feedbackMs: ms,
          correct: correct,
        );

    test('summary counts outcomes, marks and fast feedback', () {
      final summary = VoiceLogSummary.of([
        entry(VoiceOutcome.command, 400, correct: true),
        entry(VoiceOutcome.command, 900, correct: false),
        entry(VoiceOutcome.question, 1200),
        entry(VoiceOutcome.notUnderstood, null),
      ]);

      expect(summary.total, 4);
      expect(summary.executed, 2);
      expect(summary.questions, 1);
      expect(summary.notUnderstood, 1);
      expect(summary.marked, 2);
      expect(summary.markedCorrect, 1);
      expect(summary.underOneSecond, 2);
      expect(summary.timed, 3);
      expect(summary.medianMs, 900);
      expect(summary.maxMs, 1200);
    });

    test('the log survives a restart and exports as CSV', () async {
      final dir = await Directory.systemTemp.createTemp('voice_log');
      messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
      final storage = EvaluationStorage();

      await storage.save([entry(VoiceOutcome.command, 400, correct: true)]);
      final loaded = await storage.load();
      expect(loaded.single.text, 'weiter');
      expect(loaded.single.correct, isTrue);

      final path = await storage.exportCsv(loaded);
      final csv = await File(path!).readAsString();
      expect(csv, contains('"weiter";"0,90";"Befehl";"Weiter";"400";"ja"'));
      await dir.delete(recursive: true);
    });

    testWidgets('entries can be marked on the evaluation page', (
      tester,
    ) async {
      final storage = MemoryEvaluationStorage()
        ..saved = [entry(VoiceOutcome.command, 400)];
      final kitchen = await pumpApp(tester, storage: storage);
      await kitchen.loadVoiceLog();

      await tester.tap(find.byTooltip('Auswertung'));
      await tester.pumpAndSettle();
      expect(find.text('Spracheingaben'), findsOneWidget);
      expect(find.text('„weiter“'), findsOneWidget);

      await tester.tap(find.byTooltip('Richtig erkannt'));
      await tester.pump();
      expect(kitchen.voiceLog.single.correct, isTrue);
      expect(storage.saved.single.correct, isTrue);
      expect(find.text('1 von 1 (100 %)'), findsWidgets);
    });
  });
}
