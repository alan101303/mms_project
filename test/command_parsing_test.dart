import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mms_project/main.dart';

import 'fake_sounds.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ttsChannel = MethodChannel('flutter_tts');

  late KitchenController kitchen;
  late List<String> spoken;

  setUp(() async {
    spoken = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async {
          if (call.method == 'speak') spoken.add(call.arguments as String);
          return 1;
        });
    kitchen = KitchenController(sounds: FakeSoundEffects());
    await kitchen.loadRecipes();
    kitchen
      ..openRecipe(0)
      ..isPaused = false;
  });

  tearDown(() {
    kitchen.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
  });

  group('timer durations', () {
    const cases = <String, int?>{
      'timer fünf minuten': 300,
      'timer 5 minuten': 300,
      'timer fünfzehn minuten': 900,
      'timer dreißig minuten': 1800,
      'timer vierzig minuten': 2400,
      'timer fünfundzwanzig minuten': 1500,
      'stelle einen timer auf fünf minuten': 300,
      'timer eine stunde': 3600,
      'timer eine halbe stunde': 1800,
      'timer anderthalb stunden': 5400,
      'timer zweieinhalb minuten': 150,
      'timer 1,5 stunden': 5400,
      'timer 30 sekunden': 30,
      'timer eine minute und dreißig sekunden': 90,
      'timer hundertzwanzig minuten': 7200,
      'timer zehn': 600,
      'timer einstellen': null,
      'stell einen timer': null,
    };
    for (final MapEntry(key: phrase, value: seconds) in cases.entries) {
      test('„$phrase“', () async {
        await kitchen.handleCommand(phrase, 0.9);
        expect(kitchen.timerSeconds, seconds ?? 0);
        if (seconds == null) {
          expect(kitchen.feedback, startsWith('Wie lange'));
        }
      });
    }

    test('„Timer stoppen“ ends the timer', () async {
      await kitchen.handleCommand('timer fünf minuten', 0.9);
      await kitchen.handleCommand('timer stoppen', 0.9);
      expect(kitchen.timerSeconds, 0);
      expect(kitchen.feedback, 'Timer gestoppt.');
    });

    test('more than four hours is rejected', () async {
      await kitchen.handleCommand('timer fünf stunden', 0.9);
      expect(kitchen.timerSeconds, 0);
      expect(kitchen.feedback, contains('vier Stunden'));
    });

    test('long timers show hours', () async {
      await kitchen.handleCommand('timer eine stunde', 0.9);
      expect(kitchen.formattedTimer, '1:00:00');
    });
  });

  group('pause and undo', () {
    testWidgets('„Pause“ stops the timer and „Weiter“ resumes it', (
      tester,
    ) async {
      await kitchen.startTimer(const Duration(minutes: 5));
      await kitchen.handleCommand('pause', 0.9);
      await tester.pump(const Duration(seconds: 10));

      expect(kitchen.timerPaused, isTrue);
      expect(kitchen.timerSeconds, 300);

      await kitchen.handleCommand('weiter', 0.9);
      await tester.pump(const Duration(seconds: 10));

      expect(kitchen.timerPaused, isFalse);
      expect(kitchen.timerSeconds, 290);
      await kitchen.cancelTimer();
    });

    test('undo is not offered right after opening a recipe', () async {
      kitchen.openRecipe(2);
      expect(kitchen.canUndo, isFalse);
    });

    testWidgets('undoing a step leaves a running timer alone', (tester) async {
      await kitchen.startTimer(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 100));
      await kitchen.nextStep();
      await tester.pump(const Duration(seconds: 150));
      await kitchen.undo();

      expect(kitchen.stepIndex, 0);
      expect(kitchen.timerSeconds, 50);
      await kitchen.cancelTimer();
    });

    test('undoing a timer start removes the timer', () async {
      await kitchen.startTimer(const Duration(minutes: 5));
      await kitchen.undo();
      expect(kitchen.timerSeconds, 0);
    });

    test('undo that restores the paused state stays quiet', () async {
      kitchen.isPaused = true;
      await kitchen.nextStep();
      spoken.clear();

      await kitchen.undo();

      expect(kitchen.isPaused, isTrue);
      expect(kitchen.stepIndex, 0);
      expect(spoken, isEmpty);
    });

    test('undo of a pause continues the guide', () async {
      await kitchen.togglePause();
      await kitchen.undo();
      expect(kitchen.isPaused, isFalse);
    });
  });

  group('command matching', () {
    for (final phrase in [
      'nächster schritt',
      'nächste',
      'was kommt danach',
      'weiter bitte',
    ]) {
      test('„$phrase“ goes to the next step', () async {
        await kitchen.handleCommand(phrase, 0.9);
        expect(kitchen.stepIndex, 1);
      });
    }

    test('„nicht weiter“ is not a command', () async {
      await kitchen.handleCommand('nicht weiter', 0.9);
      expect(kitchen.stepIndex, 0);
      expect(kitchen.feedback, contains('nicht verstanden'));
    });

    test('„Rückgängig“ undoes the last action', () async {
      await kitchen.handleCommand('weiter', 0.9);
      await kitchen.handleCommand('rückgängig', 0.9);
      expect(kitchen.stepIndex, 0);
    });

    test('„Hilfe“ reads out the commands', () async {
      await kitchen.handleCommand('hilfe', 0.9);
      expect(kitchen.feedback, startsWith('Du kannst sagen'));
      expect(spoken.last, startsWith('Du kannst sagen'));
    });

    test('words inside other words are ignored', () async {
      // „Vorheizen“ must not count as „vorher“.
      await kitchen.handleCommand('ofen vorheizen', 0.9);
      expect(kitchen.stepIndex, 0);
      expect(kitchen.isPaused, isFalse);
    });

    for (final (phrase, name) in [
      ('tomatenpasta', 'Cremige Tomatenpasta'),
      ('pfannkuchen', 'Apfelpfannkuchen'),
      ('das ofengemüse', 'Buntes Ofengemüse'),
      ('das dritte rezept', 'Apfelpfannkuchen'),
    ]) {
      test('„$phrase“ finds $name', () async {
        expect(await kitchen.selectRecipeFromSpeech(phrase, 0.9), isTrue);
        expect(kitchen.recipe?.name, name);
      });
    }
  });

  group('recipe progress', () {
    test('reopening a recipe continues at the last step', () async {
      await kitchen.nextStep();
      await kitchen.nextStep();
      kitchen.openRecipe(1);
      expect(kitchen.stepIndex, 0);

      kitchen.openRecipe(0);
      expect(kitchen.stepIndex, 2);
      expect(kitchen.feedback, startsWith('Du warst bei Schritt 3'));
    });
  });
}
