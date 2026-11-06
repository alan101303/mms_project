import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mms_project/main.dart';

import 'fake_sounds.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ttsChannel = MethodChannel('flutter_tts');

  late FakeSoundEffects sounds;
  late KitchenController kitchen;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (_) async => 1);
    sounds = FakeSoundEffects();
    kitchen = KitchenController(sounds: sounds);
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

  test('low confidence asks about the command that was heard', () async {
    await kitchen.handleCommand('weiter', 0.2);

    expect(kitchen.pendingLabel, 'Weiter');
    expect(kitchen.feedback, contains('Meintest du „Weiter“?'));
    expect(kitchen.stepIndex, 0);
    expect(sounds.played.last, UiSound.question);

    await kitchen.handleCommand('ja', 0.9);

    expect(kitchen.stepIndex, 1);
    expect(kitchen.pendingLabel, isNull);
    expect(sounds.played.last, UiSound.success);
  });

  test('a near miss is offered as a follow-up question', () async {
    await kitchen.handleCommand('leiter', 0.9);
    expect(kitchen.pendingLabel, 'Weiter');

    await kitchen.handleCommand('nein', 0.9);
    expect(kitchen.pendingLabel, isNull);
    expect(kitchen.stepIndex, 0);
  });

  test('the follow-up question can be answered by touch', () async {
    await kitchen.nextStep();
    await kitchen.handleCommand('zurick', 0.9);
    expect(kitchen.pendingLabel, 'Zurück');

    await kitchen.answerPending(yes: true);
    expect(kitchen.stepIndex, 0);
  });

  test('a misheard timer keeps its minutes', () async {
    await kitchen.handleCommand('teimer 5 minuten', 0.9);
    expect(kitchen.pendingLabel, 'Timer 5 Minuten');

    await kitchen.handleCommand('ja', 0.9);
    expect(kitchen.timerSeconds, 300);
    await kitchen.undo();
  });

  test('a new command replaces an unanswered question', () async {
    await kitchen.handleCommand('leiter', 0.9);
    await kitchen.handleCommand('zutaten', 0.9);

    expect(kitchen.pendingLabel, isNull);
    expect(kitchen.ingredientsVisible, isTrue);
  });

  test('unknown input plays the error sound and shows help', () async {
    await kitchen.handleCommand('banane', 0.9);

    expect(kitchen.pendingLabel, isNull);
    expect(kitchen.feedback, contains('Das habe ich nicht verstanden'));
    expect(sounds.played.last, UiSound.error);
  });

  testWidgets('the alarm rings until it is switched off by voice', (
    tester,
  ) async {
    await kitchen.startTimer(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 61));

    expect(kitchen.alarmRinging, isTrue);
    expect(sounds.alarmPlaying, isTrue);

    await kitchen.handleCommand('stopp', 0.9);

    expect(kitchen.alarmRinging, isFalse);
    expect(sounds.alarmPlaying, isFalse);
    expect(kitchen.isPaused, isFalse);
  });

  testWidgets('the alarm stops by itself after two minutes', (tester) async {
    await kitchen.startTimer(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 61));
    expect(kitchen.alarmRinging, isTrue);

    await tester.pump(const Duration(minutes: 2));
    expect(kitchen.alarmRinging, isFalse);
    expect(sounds.alarmPlaying, isFalse);
  });
}
