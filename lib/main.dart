import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => KitchenController()..loadRecipes(),
      child: const KitchenApp(),
    ),
  );
}

const _ink = Color(0xFF24332D);
const _green = Color(0xFF3C684F);
const _cream = Color(0xFFF7F5EF);
// Mic colours from the help sketch: green = listening, grey = not listening.
const _micOn = Color(0xFF2E9D57);
const _micOff = Color(0xFF7A7F78);

class KitchenApp extends StatelessWidget {
  const KitchenApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Küchenstimme',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _cream,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _green,
        primary: _green,
        surface: _cream,
      ),
      fontFamily: 'Roboto',
    ),
    home: const KitchenHomePage(),
  );
}

class Recipe {
  const Recipe({
    required this.name,
    required this.description,
    required this.duration,
    required this.icon,
    required this.ingredients,
    required this.steps,
  });

  final String name;
  final String description;
  final int duration;
  final String icon;
  final List<String> ingredients;
  final List<String> steps;

  factory Recipe.fromJson(Map<String, dynamic> json) => Recipe(
    name: json['name'] as String,
    description: json['description'] as String,
    duration: json['duration'] as int,
    icon: json['icon'] as String,
    ingredients: (json['ingredients'] as List<dynamic>).cast<String>(),
    steps: (json['steps'] as List<dynamic>).cast<String>(),
  );
}

class _KitchenSnapshot {
  const _KitchenSnapshot({
    required this.recipeIndex,
    required this.stepIndex,
    required this.paused,
    required this.timerSeconds,
  });

  final int recipeIndex;
  final int stepIndex;
  final bool paused;
  final int timerSeconds;
}

/// Where the hands-free voice loop currently is.
enum VoiceState { idle, listening, processing, speaking }

/// Non-speech sounds that confirm voice input.
enum UiSound { heard, success, question, error }

enum _VoiceCommand { previous, repeat, ingredients, timer, pause, next }

/// Plays the bundled UI sounds and the looping timer alarm.
class SoundEffects {
  AudioPlayer? _effects;
  AudioPlayer? _alarm;

  Future<void> play(UiSound sound) async {
    try {
      final player = _effects ??= await _createPlayer(
        AndroidUsageType.assistanceSonification,
        AndroidAudioFocus.none,
      );
      await player.stop();
      await player.play(
        AssetSource('sounds/${sound.name}.wav'),
        mode: PlayerMode.lowLatency,
      );
    } catch (_) {
      // A missing sound must never break voice control.
    }
  }

  Future<void> startAlarm() async {
    try {
      final player = _alarm ??= await _createPlayer(
        AndroidUsageType.alarm,
        AndroidAudioFocus.gainTransientMayDuck,
      );
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(AssetSource('sounds/alarm.wav'));
    } catch (_) {
      // The visual alarm still works without sound.
    }
  }

  Future<void> stopAlarm() async {
    try {
      await _alarm?.stop();
    } catch (_) {
      // Nothing left to stop.
    }
  }

  Future<AudioPlayer> _createPlayer(
    AndroidUsageType usage,
    AndroidAudioFocus focus,
  ) async {
    final player = AudioPlayer();
    await player.setAudioContext(
      AudioContext(
        android: AudioContextAndroid(
          usageType: usage,
          contentType: AndroidContentType.sonification,
          audioFocus: focus,
        ),
      ),
    );
    return player;
  }

  void dispose() {
    unawaited(_effects?.dispose());
    unawaited(_alarm?.dispose());
  }
}

class KitchenController extends ChangeNotifier {
  KitchenController({SoundEffects? sounds})
    : _sounds = sounds ?? SoundEffects();

  static const homeHint = 'Tippe auf das Mikrofon und nenne ein Rezept.';
  static const _minConfidence = 0.35;
  static const _yesWords = {'ja', 'jawohl', 'genau', 'richtig', 'okay', 'ok'};
  static const _noWords = {'nein', 'nee', 'ne', 'nö', 'falsch'};
  static const _fuzzyKeywords = [
    'weiter',
    'zurück',
    'wiederholen',
    'nochmal',
    'zutaten',
    'timer',
    'pause',
    'stopp',
    'fortsetzen',
  ];

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final SoundEffects _sounds;
  final List<Recipe> recipes = [];
  Timer? _timer;
  Timer? _restartTimer;
  Timer? _alarmTimeout;
  Completer<void>? _speechDone;
  Future<void> Function(String text, double confidence)? _resultHandler;
  _KitchenSnapshot? _undoSnapshot;
  bool _speechInitialized = false;
  bool _ttsConfigured = false;
  bool _heardFeedback = false;
  bool _handlingCommand = false;
  int _speechToken = 0;
  String? _pendingCommand;
  int _recipeIndex = 0;
  int stepIndex = 0;
  int timerSeconds = 0;
  bool handsFree = false;
  bool alarmRinging = false;
  VoiceState voiceState = VoiceState.idle;
  bool isPaused = false;
  bool isLoading = true;
  String recognizedText = '';
  String feedback = homeHint;
  String? pendingLabel;
  String selectedInput = 'Stimme';

  Recipe? get recipe => recipes.isEmpty ? null : recipes[_recipeIndex];
  bool get canUndo => _undoSnapshot != null;
  bool get isListening => voiceState == VoiceState.listening;

  String get voiceStatus => switch (voiceState) {
    VoiceState.listening => 'Ich höre zu …',
    VoiceState.processing => 'Verarbeite …',
    VoiceState.speaking => 'Ich spreche …',
    VoiceState.idle => handsFree ? 'Gleich wieder bereit …' : 'Mikrofon aus',
  };

  void setInputMode(String mode) {
    selectedInput = mode;
    notifyListeners();
  }

  Future<void> loadRecipes() async {
    try {
      final json = await rootBundle.loadString('assets/recipes.json');
      final decoded = jsonDecode(json) as List<dynamic>;
      recipes
        ..clear()
        ..addAll(
          decoded.map((item) => Recipe.fromJson(item as Map<String, dynamic>)),
        );
      if (recipes.isEmpty) {
        feedback = 'Keine Rezepte gefunden.';
      }
    } on FormatException catch (error) {
      feedback = 'Die Rezeptdaten sind ungültig: ${error.message}';
    } on FlutterError catch (error) {
      feedback =
          'Die Rezeptdaten konnten nicht geladen werden: ${error.message}';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _configureSpeech() async {
    if (_speechInitialized) return;

    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      feedback = granted.isPermanentlyDenied
          ? 'Mikrofonzugriff fehlt. Bitte erlaube ihn in den Einstellungen.'
          : 'Für die Sprachsteuerung wird Mikrofonzugriff benötigt.';
      notifyListeners();
      return;
    }

    _speechInitialized = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
    );
    if (!_speechInitialized) {
      feedback = 'Spracherkennung nicht verfügbar. Bitte prüfe die Spracheinstellungen.';
      notifyListeners();
    }
  }

  /// Turns hands-free mode on or off. While it is on, the app keeps listening
  /// for commands until the mic is tapped again or the cooking page closes.
  Future<void> toggleListening({
    Future<void> Function(String text, double confidence)? onFinalResult,
  }) async {
    if (handsFree) {
      await stopVoice();
      return;
    }

    await _configureSpeech();
    if (!_speechInitialized) return;
    _resultHandler = onFinalResult;
    handsFree = true;
    feedback = 'Sprachsteuerung ist an.';
    notifyListeners();
    await _tts.stop();
    await _startListening();
  }

  Future<void> stopVoice() async {
    if (!handsFree && voiceState == VoiceState.idle) return;
    handsFree = false;
    _restartTimer?.cancel();
    _clearPending();
    voiceState = VoiceState.idle;
    notifyListeners();
    if (_speechInitialized) await _speech.cancel();
  }

  /// Called when the cooking page closes: silence the app and reset the hint.
  Future<void> leaveRecipe() async {
    await stopVoice();
    recognizedText = '';
    feedback = homeHint;
    notifyListeners();
    await _tts.stop();
  }

  Future<void> _startListening() async {
    if (!handsFree || voiceState != VoiceState.idle) return;
    _heardFeedback = false;
    voiceState = VoiceState.listening;
    notifyListeners();
    try {
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: 'de_DE',
          listenFor: const Duration(seconds: 20),
          pauseFor: const Duration(seconds: 3),
        ),
        onResult: _onSpeechResult,
      );
    } on ListenFailedException catch (error) {
      voiceState = VoiceState.idle;
      feedback = 'Spracherkennung konnte nicht starten: ${error.message}';
      notifyListeners();
      _scheduleRestart(const Duration(seconds: 1));
    }
  }

  void _scheduleRestart([Duration delay = const Duration(milliseconds: 300)]) {
    _restartTimer?.cancel();
    if (!handsFree) return;
    _restartTimer = Timer(delay, () => unawaited(_startListening()));
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    // Results that arrive while the app is talking or busy are stale.
    if (!handsFree ||
        (voiceState != VoiceState.listening && voiceState != VoiceState.idle)) {
      return;
    }
    if (result.recognizedWords.trim().isEmpty) return;
    recognizedText = result.recognizedWords;
    if (!_heardFeedback) {
      _heardFeedback = true;
      unawaited(_sounds.play(UiSound.heard));
    }
    if (result.finalResult) {
      _restartTimer?.cancel();
      voiceState = VoiceState.processing;
      unawaited(_processResult(recognizedText, result.confidence));
    }
    notifyListeners();
  }

  Future<void> _processResult(String text, double confidence) async {
    _handlingCommand = true;
    try {
      await (_resultHandler ?? handleCommand)(text, confidence);
    } finally {
      _handlingCommand = false;
      if (voiceState == VoiceState.processing) voiceState = VoiceState.idle;
      notifyListeners();
      _scheduleRestart();
    }
  }

  void _onSpeechStatus(String status) {
    // A session that ends without a final result (silence) starts over.
    if (status == SpeechToText.doneStatus &&
        voiceState == VoiceState.listening) {
      voiceState = VoiceState.idle;
      notifyListeners();
      _scheduleRestart();
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    // Errors from cancelling the mic for speech output don't matter.
    if (voiceState != VoiceState.listening && voiceState != VoiceState.idle) {
      return;
    }
    switch (error.errorMsg) {
      case 'error_no_match' ||
          'error_speech_timeout' ||
          'error_client' ||
          'error_busy':
        // Silence or a busy recognizer: just listen again.
        voiceState = VoiceState.idle;
        notifyListeners();
        _scheduleRestart(const Duration(seconds: 1));
        return;
    }
    handsFree = false;
    _restartTimer?.cancel();
    voiceState = VoiceState.idle;
    feedback = _describeSpeechError(error.errorMsg);
    notifyListeners();
    unawaited(_sounds.play(UiSound.error));
  }

  static String _describeSpeechError(String code) => switch (code) {
    'error_network' ||
    'error_network_timeout' ||
    'error_server' ||
    'error_server_disconnected' =>
      'Die Spracherkennung braucht eine Internetverbindung. '
          'Tippe auf das Mikrofon, um es erneut zu versuchen.',
    'error_permission' || 'error_insufficient_permissions' =>
      'Mikrofonzugriff fehlt. Bitte erlaube ihn in den Einstellungen.',
    'error_language_not_supported' || 'error_language_unavailable' =>
      'Deutsche Spracherkennung ist auf diesem Gerät nicht verfügbar.',
    _ =>
      'Spracherkennung unterbrochen ($code). '
          'Tippe auf das Mikrofon, um sie neu zu starten.',
  };

  Future<bool> selectRecipeFromSpeech(String text, double confidence) async {
    recognizedText = text;
    final normalized = text.toLowerCase().trim();

    if (confidence > 0 && confidence < _minConfidence) {
      unawaited(_sounds.play(UiSound.question));
      feedback =
          'Ich bin nicht sicher. Bitte sage den Rezeptnamen noch einmal.';
      notifyListeners();
      await _speak(feedback);
      return false;
    }

    final index = _findRecipeIndex(normalized);
    if (index == null) {
      unawaited(_sounds.play(UiSound.error));
      feedback = 'Ich habe das Rezept nicht erkannt. Sage zum Beispiel „Cremige Tomatenpasta“.';
      notifyListeners();
      await _speak(feedback);
      return false;
    }

    unawaited(_sounds.play(UiSound.success));
    openRecipe(index);
    feedback = '${recipes[index].name} ausgewählt.';
    notifyListeners();
    return true;
  }

  /// Spoken confirmation after a recipe was chosen by voice.
  Future<void> announceRecipe() async {
    final current = recipe;
    if (current == null) return;
    await _speak('${current.name}. Sag „Weiter“, wenn du bereit bist.');
  }

  void _saveUndo() {
    _undoSnapshot = _KitchenSnapshot(
      recipeIndex: _recipeIndex,
      stepIndex: stepIndex,
      paused: isPaused,
      timerSeconds: timerSeconds,
    );
  }

  Future<void> undo() async {
    final snapshot = _undoSnapshot;
    if (snapshot == null) return;
    _timer?.cancel();
    _recipeIndex = snapshot.recipeIndex;
    stepIndex = snapshot.stepIndex;
    isPaused = snapshot.paused;
    timerSeconds = snapshot.timerSeconds;
    _undoSnapshot = null;
    if (timerSeconds > 0) _startTimerTicker();
    feedback = 'Letzte Aktion rückgängig gemacht.';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> selectRecipe(int index) async {
    if (index < 0 || index >= recipes.length || index == _recipeIndex) return;
    _saveUndo();
    _recipeIndex = index;
    stepIndex = 0;
    isPaused = false;
    ingredientsVisible = false;
    feedback = 'Rezept ausgewählt.';
    notifyListeners();
    await _readCurrentStep();
  }

  void openRecipe(int index) {
    if (index < 0 || index >= recipes.length) return;
    _saveUndo();
    _recipeIndex = index;
    stepIndex = 0;
    isPaused = true;
    ingredientsVisible = false;
    // From here on, voice input is handled as cooking commands.
    _resultHandler = null;
    feedback = 'Sag „Weiter“ oder tippe auf Start, wenn du bereit bist.';
    notifyListeners();
  }

  Future<void> nextStep() async {
    final current = recipe;
    if (current == null) return;
    if (stepIndex >= current.steps.length - 1) {
      feedback = 'Das war der letzte Schritt. Guten Appetit!';
      await _speak(feedback);
      notifyListeners();
      return;
    }
    _saveUndo();
    stepIndex++;
    isPaused = false;
    feedback = 'Schritt ${stepIndex + 1} von ${current.steps.length}';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> previousStep() async {
    if (stepIndex == 0) {
      feedback = 'Du bist schon beim ersten Schritt.';
      notifyListeners();
      return;
    }
    _saveUndo();
    stepIndex--;
    isPaused = false;
    feedback = 'Schritt ${stepIndex + 1} von ${recipe!.steps.length}';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> repeatStep() async {
    isPaused = false;
    feedback = 'Ich wiederhole den Schritt.';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> togglePause() async {
    _saveUndo();
    isPaused = !isPaused;
    if (isPaused) {
      feedback = 'Anleitung pausiert.';
      notifyListeners();
      await _tts.stop();
    } else {
      feedback = 'Weiter geht’s.';
      notifyListeners();
      await _readCurrentStep();
    }
    notifyListeners();
  }

  void showIngredients() {
    ingredientsVisible = true;
    feedback = 'Zutaten für ${recipe?.name ?? 'das Rezept'}';
    notifyListeners();
  }

  bool ingredientsVisible = false;

  Future<void> startTimer(int minutes) async {
    if (minutes < 1 || minutes > 240) {
      feedback = 'Bitte nenne eine Zeit zwischen 1 und 240 Minuten.';
      notifyListeners();
      return;
    }
    await stopAlarm();
    _saveUndo();
    _timer?.cancel();
    timerSeconds = minutes * 60;
    feedback = 'Timer auf $minutes Minuten gestellt.';
    _startTimerTicker();
    notifyListeners();
    await _speak(feedback);
  }

  void _startTimerTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timerSeconds <= 1) {
        timerSeconds = 0;
        timer.cancel();
        _ringAlarm();
      } else {
        timerSeconds--;
      }
      notifyListeners();
    });
  }

  void _ringAlarm() {
    alarmRinging = true;
    feedback =
        'Der Timer ist abgelaufen. Sag „Stopp“ oder tippe auf „Alarm aus“.';
    unawaited(_sounds.startAlarm());
    _alarmTimeout?.cancel();
    _alarmTimeout = Timer(
      const Duration(minutes: 2),
      () => unawaited(stopAlarm()),
    );
  }

  Future<void> stopAlarm() async {
    if (!alarmRinging) return;
    alarmRinging = false;
    _alarmTimeout?.cancel();
    feedback = 'Alarm aus.';
    notifyListeners();
    await _sounds.stopAlarm();
  }

  Future<void> _readCurrentStep() async {
    final current = recipe;
    if (current == null || current.steps.isEmpty) return;
    await _speak('Schritt ${stepIndex + 1}. ${current.steps[stepIndex]}');
  }

  Future<void> _configureTts() async {
    if (_ttsConfigured) return;
    _ttsConfigured = true;
    // These handlers also fire when speech is stopped or interrupted.
    // awaitSpeakCompletion(true) can't be used: on Android, a stopped
    // utterance never completes the awaited speak() call.
    _tts
      ..setCompletionHandler(_finishSpeaking)
      ..setCancelHandler(_finishSpeaking)
      ..setErrorHandler((_) => _finishSpeaking());
    await _tts.setLanguage('de-DE');
    await _tts.setSpeechRate(0.48);
  }

  void _finishSpeaking() {
    final done = _speechDone;
    _speechDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _speak(String text) async {
    await _configureTts();
    if (!handsFree) {
      await _tts.speak(text);
      return;
    }

    // In hands-free mode the mic is closed while the app talks, so it can't
    // hear itself, and reopened once the speech has finished.
    final token = ++_speechToken;
    _restartTimer?.cancel();
    voiceState = VoiceState.speaking;
    notifyListeners();
    if (_speechInitialized) await _speech.cancel();
    _finishSpeaking();
    final done = _speechDone = Completer<void>();
    final started = await _tts.speak(text);
    if (started != 1) _finishSpeaking();
    // Fallback in case the engine never reports the end of the utterance.
    await done.future.timeout(const Duration(minutes: 2), onTimeout: () {});

    // A newer utterance took over and will reopen the mic itself.
    if (token != _speechToken) return;
    if (voiceState == VoiceState.speaking) {
      voiceState = _handlingCommand ? VoiceState.processing : VoiceState.idle;
      notifyListeners();
    }
    if (!_handlingCommand) _scheduleRestart();
  }

  Future<void> handleCommand(String text, double confidence) async {
    final command = text.toLowerCase().trim();
    if (command.isEmpty) return;
    recognizedText = text;

    if (alarmRinging) {
      // Whatever is said while the alarm rings switches it off.
      unawaited(_sounds.play(UiSound.success));
      await stopAlarm();
      return;
    }

    if (_pendingCommand != null) {
      if (_words(command).any(_yesWords.contains)) {
        return answerPending(yes: true);
      }
      if (_words(command).any(_noWords.contains)) {
        return answerPending(yes: false);
      }
      // Anything else is treated as a new command.
      _clearPending();
    }

    await _dispatch(
      command,
      lowConfidence: confidence > 0 && confidence < _minConfidence,
    );
  }

  /// Answers the open „Meintest du …?“ question, by voice or by touch.
  Future<void> answerPending({required bool yes}) async {
    final pending = _pendingCommand;
    if (pending == null) return;
    _clearPending();
    if (yes) {
      await _dispatch(pending, lowConfidence: false);
      return;
    }
    feedback = 'Okay. Sag den Befehl bitte noch einmal.';
    notifyListeners();
    await _speak(feedback);
  }

  Future<void> _dispatch(String command, {required bool lowConfidence}) async {
    final type = _detectCommand(command);
    if (type != null) {
      if (lowConfidence) {
        return _askToConfirm(command, _commandLabel(type, command));
      }
      unawaited(_sounds.play(UiSound.success));
      return _runCommand(type, command);
    }

    final recipeIndex = _findRecipeIndex(command);
    if (recipeIndex != null) {
      if (lowConfidence) {
        return _askToConfirm(command, recipes[recipeIndex].name);
      }
      unawaited(_sounds.play(UiSound.success));
      return selectRecipe(recipeIndex);
    }

    final corrected = _fuzzyCorrect(command);
    if (corrected != null) {
      final guess = _detectCommand(corrected);
      if (guess != null) {
        return _askToConfirm(corrected, _commandLabel(guess, corrected));
      }
    }

    unawaited(_sounds.play(UiSound.error));
    feedback = 'Das habe ich nicht verstanden. Sag zum Beispiel „Weiter“, „Zurück“ oder „Timer fünf Minuten“.';
    notifyListeners();
    await _speak(feedback);
  }

  Future<void> _askToConfirm(String command, String label) async {
    _pendingCommand = command;
    pendingLabel = label;
    unawaited(_sounds.play(UiSound.question));
    feedback = 'Meintest du „$label“? Sag „Ja“ oder „Nein“.';
    notifyListeners();
    await _speak(feedback);
  }

  void _clearPending() {
    _pendingCommand = null;
    pendingLabel = null;
  }

  static _VoiceCommand? _detectCommand(String command) {
    if (command.contains('zurück') ||
        command.contains('zurueck') ||
        command.contains('vorher')) {
      return _VoiceCommand.previous;
    }
    if (command.contains('wiederhol') ||
        command.contains('nochmal') ||
        command.contains('noch einmal')) {
      return _VoiceCommand.repeat;
    }
    if (command.contains('zutat') ||
        command.contains('einkauf') ||
        command.contains('was brauche')) {
      return _VoiceCommand.ingredients;
    }
    if (command.contains('timer')) return _VoiceCommand.timer;
    if (command.contains('pause') ||
        command.contains('stopp') ||
        command.contains('stop')) {
      return _VoiceCommand.pause;
    }
    if (command.contains('fortsetzen') || command.contains('weiter')) {
      return _VoiceCommand.next;
    }
    return null;
  }

  String _commandLabel(_VoiceCommand type, String command) => switch (type) {
    _VoiceCommand.previous => 'Zurück',
    _VoiceCommand.repeat => 'Wiederholen',
    _VoiceCommand.ingredients => 'Zutaten',
    _VoiceCommand.timer => switch (_parseMinutes(command)) {
      final minutes? => 'Timer $minutes Minuten',
      null => 'Timer',
    },
    _VoiceCommand.pause => 'Pause',
    _VoiceCommand.next => 'Weiter',
  };

  Future<void> _runCommand(_VoiceCommand type, String command) async {
    switch (type) {
      case _VoiceCommand.previous:
        await previousStep();
      case _VoiceCommand.repeat:
        await repeatStep();
      case _VoiceCommand.ingredients:
        showIngredients();
        final ingredients = recipe?.ingredients.join(', ');
        if (ingredients != null) {
          await _speak('Die Zutaten sind: $ingredients.');
        }
      case _VoiceCommand.timer:
        final minutes = _parseMinutes(command);
        if (minutes == null) {
          feedback = 'Wie viele Minuten soll der Timer laufen?';
          notifyListeners();
          await _speak(feedback);
        } else {
          await startTimer(minutes);
        }
      case _VoiceCommand.pause:
        if (!isPaused) await togglePause();
      case _VoiceCommand.next:
        if (isPaused) {
          await togglePause();
        } else {
          await nextStep();
        }
    }
  }

  static Iterable<String> _words(String command) => command
      .split(RegExp(r'[^a-zäöüß0-9]+'))
      .where((word) => word.isNotEmpty);

  /// Replaces a word that is close to a command keyword, e.g. „leiter“ with
  /// „weiter“, so the app can ask whether that command was meant.
  static String? _fuzzyCorrect(String command) {
    final words = _words(command).toList();
    String? best;
    var bestIndex = -1;
    var bestDistance = 3;
    for (var i = 0; i < words.length; i++) {
      if (words[i].length < 4) continue;
      for (final keyword in _fuzzyKeywords) {
        final allowed = keyword.length <= 5 ? 1 : 2;
        final distance = _editDistance(words[i], keyword);
        if (distance <= allowed && distance < bestDistance) {
          best = keyword;
          bestIndex = i;
          bestDistance = distance;
        }
      }
    }
    if (best == null) return null;
    words[bestIndex] = best;
    return words.join(' ');
  }

  static int _editDistance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, i);
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          current[j - 1] + 1,
          previous[j] + 1,
          previous[j - 1] + cost,
        ].reduce(min);
      }
      previous = current;
    }
    return previous[b.length];
  }

  int? _findRecipeIndex(String command) {
    for (var index = 0; index < recipes.length; index++) {
      final number = switch (index + 1) {
        1 => 'eins',
        2 => 'zwei',
        3 => 'drei',
        _ => '${index + 1}',
      };
      if (command.contains(recipes[index].name.toLowerCase()) ||
          command.contains('rezept $number') ||
          command.contains('rezept ${index + 1}')) {
        return index;
      }
    }
    return null;
  }

  int? _parseMinutes(String command) {
    final digit = RegExp(r'\d+').firstMatch(command);
    if (digit != null) return int.tryParse(digit.group(0)!);
    const numbers = <String, int>{
      'eine': 1,
      'einer': 1,
      'ein': 1,
      'zwei': 2,
      'drei': 3,
      'vier': 4,
      'fünf': 5,
      'fuenf': 5,
      'sechs': 6,
      'sieben': 7,
      'acht': 8,
      'neun': 9,
      'zehn': 10,
      'elf': 11,
      'zwölf': 12,
      'zwoelf': 12,
      'fünfzehn': 15,
      'fuenfzehn': 15,
      'zwanzig': 20,
      'dreißig': 30,
      'dreissig': 30,
    };
    for (final entry in numbers.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    return null;
  }

  String get formattedTimer {
    final minutes = (timerSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (timerSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _restartTimer?.cancel();
    _alarmTimeout?.cancel();
    unawaited(_speech.cancel());
    unawaited(_tts.stop());
    _sounds.dispose();
    super.dispose();
  }
}

class KitchenHomePage extends StatelessWidget {
  const KitchenHomePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Consumer<KitchenController>(
        builder: (context, kitchen, _) {
          if (kitchen.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE7EBDD),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: const Icon(
                            Icons.restaurant_menu,
                            color: _green,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Küchenstimme',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Hilfe und Sprachbefehle',
                          onPressed: () {
                            unawaited(kitchen.stopVoice());
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const SpeechHelpPage(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.help_outline_rounded),
                          color: _green,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    const Text(
                      'Was kochen wir?',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 29,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Wähle ein Rezept und lass dich Schritt für Schritt begleiten.',
                      style: TextStyle(
                        color: Color(0xFF71766F),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _HomeVoiceCard(
                      kitchen: kitchen,
                      onFinalResult: (text, confidence) async {
                        final selected = await kitchen.selectRecipeFromSpeech(
                          text,
                          confidence,
                        );
                        if (!selected || !context.mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const RecipeCookingPage(),
                          ),
                        );
                        await kitchen.announceRecipe();
                      },
                    ),
                    if (kitchen.timerSeconds > 0 || kitchen.alarmRinging) ...[
                      const SizedBox(height: 12),
                      _TimerCard(kitchen: kitchen),
                    ],
                    const SizedBox(height: 22),
                    ...List.generate(
                      kitchen.recipes.length,
                      (index) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RecipeListTile(
                          recipe: kitchen.recipes[index],
                          onTap: () {
                            kitchen.openRecipe(index);
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const RecipeCookingPage(),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _HomeVoiceCard extends StatelessWidget {
  const _HomeVoiceCard({required this.kitchen, required this.onFinalResult});

  final KitchenController kitchen;
  final Future<void> Function(String text, double confidence) onFinalResult;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    decoration: BoxDecoration(
      color: const Color(0xFFE9EDE3),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                kitchen.handsFree ? kitchen.voiceStatus : 'Rezept ansagen',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              if (kitchen.recognizedText.isNotEmpty)
                Text(
                  'Erkannt: „${kitchen.recognizedText}“',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              Text(
                kitchen.feedback,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF59645A),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _MicButton(
          kitchen: kitchen,
          idleTooltip: 'Rezept per Sprache auswählen',
          onPressed: () =>
              kitchen.toggleListening(onFinalResult: onFinalResult),
          size: 48,
        ),
      ],
    ),
  );
}

/// Green while listening, grey otherwise; the icon shows when the app talks.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.kitchen,
    required this.idleTooltip,
    required this.onPressed,
    required this.size,
  });

  final KitchenController kitchen;
  final String idleTooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton.filled(
    tooltip: kitchen.handsFree ? 'Sprachsteuerung beenden' : idleTooltip,
    onPressed: onPressed,
    icon: Icon(switch (kitchen.voiceState) {
      VoiceState.listening => Icons.mic,
      VoiceState.speaking => Icons.volume_up_rounded,
      _ => kitchen.handsFree ? Icons.mic_none_rounded : Icons.mic_off_rounded,
    }),
    iconSize: size * 0.45,
    style: IconButton.styleFrom(
      backgroundColor: kitchen.isListening ? _micOn : _micOff,
      foregroundColor: Colors.white,
      fixedSize: Size(size, size),
    ),
  );
}

class _RecipeListTile extends StatelessWidget {
  const _RecipeListTile({required this.recipe, required this.onTap});

  final Recipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Container(
              width: 66,
              height: 66,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF4F1E9),
                borderRadius: BorderRadius.circular(17),
              ),
              child: Text(recipe.icon, style: const TextStyle(fontSize: 34)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recipe.name,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    recipe.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF777D74),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '${recipe.duration} Min. · ${recipe.steps.length} Schritte',
                    style: const TextStyle(
                      color: _green,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: _green),
          ],
        ),
      ),
    ),
  );
}

class SpeechHelpPage extends StatelessWidget {
  const SpeechHelpPage({super.key});

  static const _commands = <(IconData, String, String)>[
    (
      Icons.restaurant_menu_rounded,
      'Rezept auswählen',
      'Sage den Rezeptnamen, zum Beispiel „Cremige Tomatenpasta“, oder „Rezept zwei“.',
    ),
    (
      Icons.arrow_forward_rounded,
      'Weiter',
      'Zum nächsten Zubereitungsschritt.',
    ),
    (Icons.arrow_back_rounded, 'Zurück', 'Zum vorherigen Zubereitungsschritt.'),
    (
      Icons.replay_rounded,
      'Nochmal',
      'Liest den aktuellen Schritt erneut vor.',
    ),
    (
      Icons.menu_book_rounded,
      'Zutaten',
      'Zeigt die Zutaten des ausgewählten Rezepts.',
    ),
    (
      Icons.timer_outlined,
      'Timer fünf Minuten',
      'Startet einen Timer. Die Zeit kann zwischen 1 und 240 Minuten liegen.',
    ),
    (
      Icons.pause_rounded,
      'Pause',
      'Pausiert die gesprochene Anleitung. Mit „Weiter“ geht es weiter.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Zurück',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: const Text('Hilfe und Sprachbefehle'),
      titleTextStyle: const TextStyle(
        color: _ink,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
      backgroundColor: _cream,
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        const Text(
          'Sag einfach, was du brauchst.',
          style: TextStyle(
            color: _ink,
            fontSize: 23,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Tippe auf das Mikrofon und nenne einen Befehl. Auf der Startseite '
          'kannst du ein Rezept per Namen oder Nummer auswählen.',
          style: TextStyle(
            color: Color(0xFF71766F),
            fontSize: 14,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 18),
        ..._commands.map(
          (command) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(command.$1, color: _green, size: 22),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          command.$2,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          command.$3,
                          style: const TextStyle(
                            color: Color(0xFF71766F),
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: const Color(0xFFE9EDE3),
            borderRadius: BorderRadius.circular(17),
          ),
          child: const Text(
            'Du kannst alle Funktionen auch jederzeit über die Symbole in der '
            'Kochansicht bedienen. Die Spracherkennung benötigt '
            'Mikrofonzugriff und eine deutsche Spracherkennung auf deinem Gerät.',
            style: TextStyle(
              color: Color(0xFF59645A),
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

class RecipeCookingPage extends StatefulWidget {
  const RecipeCookingPage({super.key});

  @override
  State<RecipeCookingPage> createState() => _RecipeCookingPageState();
}

class _RecipeCookingPageState extends State<RecipeCookingPage> {
  @override
  void initState() {
    super.initState();
    // Keep the screen on while cooking; hands are often wet or busy.
    unawaited(_setWakelock(true));
  }

  @override
  void dispose() {
    unawaited(_setWakelock(false));
    super.dispose();
  }

  Future<void> _setWakelock(bool enabled) async {
    try {
      await WakelockPlus.toggle(enable: enabled);
    } catch (_) {
      // Not available (for example in tests); the app works without it.
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) unawaited(context.read<KitchenController>().leaveRecipe());
    },
    child: _buildPage(),
  );

  Widget _buildPage() => Consumer<KitchenController>(
    builder: (context, kitchen, _) {
      final recipe = kitchen.recipe;
      if (recipe == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }

      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 18, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Zur Rezeptliste',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: _ink,
                    ),
                    Expanded(
                      child: Text(
                        recipe.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Letzte Aktion rückgängig',
                      onPressed: kitchen.canUndo ? kitchen.undo : null,
                      icon: const Icon(Icons.undo_rounded),
                      color: _green,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  children: [
                    Row(
                      children: [
                        Text(
                          'SCHRITT ${kitchen.stepIndex + 1}',
                          style: const TextStyle(
                            color: _green,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.3,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${kitchen.stepIndex + 1} / ${recipe.steps.length}',
                          style: const TextStyle(
                            color: Color(0xFF888C83),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: LinearProgressIndicator(
                        value: (kitchen.stepIndex + 1) / recipe.steps.length,
                        minHeight: 5,
                        backgroundColor: const Color(0xFFE6E8E1),
                        color: _green,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x0C27362D),
                            blurRadius: 18,
                            offset: Offset(0, 7),
                          ),
                        ],
                      ),
                      child: Text(
                        recipe.steps[kitchen.stepIndex],
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 20,
                          height: 1.55,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (kitchen.timerSeconds > 0 || kitchen.alarmRinging) ...[
                      const SizedBox(height: 16),
                      _TimerCard(kitchen: kitchen),
                    ],
                    if (kitchen.ingredientsVisible) ...[
                      const SizedBox(height: 16),
                      _InlineIngredients(recipe: recipe),
                    ],
                    const SizedBox(height: 26),
                    _CookingControls(kitchen: kitchen),
                  ],
                ),
              ),
              _MicrophoneDock(kitchen: kitchen),
            ],
          ),
        ),
      );
    },
  );
}

class _CookingControls extends StatelessWidget {
  const _CookingControls({required this.kitchen});

  final KitchenController kitchen;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      _IconControl(
        icon: Icons.arrow_back_rounded,
        label: 'Vorheriger Schritt',
        onPressed: kitchen.previousStep,
      ),
      _IconControl(
        icon: kitchen.isPaused ? Icons.play_arrow_rounded : Icons.stop_rounded,
        label: kitchen.isPaused ? 'Anleitung starten' : 'Anleitung stoppen',
        prominent: true,
        onPressed: kitchen.togglePause,
      ),
      _IconControl(
        icon: Icons.arrow_forward_rounded,
        label: 'Nächster Schritt',
        onPressed: kitchen.nextStep,
      ),
      _IconControl(
        icon: Icons.replay_rounded,
        label: 'Schritt wiederholen',
        onPressed: kitchen.repeatStep,
      ),
      _IconControl(
        icon: Icons.timer_outlined,
        label: 'Timer einstellen',
        onPressed: () => _showTimerDialog(context, kitchen),
      ),
      _IconControl(
        icon: Icons.menu_book_rounded,
        label: 'Zutaten anzeigen',
        onPressed: kitchen.showIngredients,
      ),
    ],
  );
}

class _IconControl extends StatelessWidget {
  const _IconControl({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon),
        iconSize: 21,
        style: IconButton.styleFrom(
          backgroundColor: prominent ? _green : Colors.white,
          foregroundColor: prominent ? Colors.white : _ink,
          minimumSize: const Size(44, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
      ),
    ),
  );
}

class _MicrophoneDock extends StatelessWidget {
  const _MicrophoneDock({required this.kitchen});

  final KitchenController kitchen;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
    decoration: const BoxDecoration(
      color: _cream,
      border: Border(top: BorderSide(color: Color(0xFFE9E7DF))),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (kitchen.recognizedText.isNotEmpty)
          Text(
            'Erkannt: „${kitchen.recognizedText}“',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        Text(
          kitchen.feedback,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF59645A),
            fontSize: 13,
            height: 1.35,
          ),
        ),
        if (kitchen.pendingLabel != null) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => kitchen.answerPending(yes: false),
                child: const Text('Nein'),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () => kitchen.answerPending(yes: true),
                child: Text('Ja, ${kitchen.pendingLabel}'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        _MicButton(
          kitchen: kitchen,
          idleTooltip: 'Sprachbefehl geben',
          onPressed: kitchen.toggleListening,
          size: 62,
        ),
        const SizedBox(height: 4),
        Text(
          kitchen.voiceStatus,
          style: const TextStyle(
            color: Color(0xFF59645A),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _InlineIngredients extends StatelessWidget {
  const _InlineIngredients({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFFE9EDE3),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Zutaten für ${recipe.name}',
          style: const TextStyle(
            color: _ink,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        ...recipe.ingredients.map(
          (ingredient) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              '·  $ingredient',
              style: const TextStyle(color: Color(0xFF59645A), fontSize: 13),
            ),
          ),
        ),
      ],
    ),
  );
}

class _TimerCard extends StatelessWidget {
  const _TimerCard({required this.kitchen});

  final KitchenController kitchen;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
    decoration: BoxDecoration(
      color: kitchen.alarmRinging
          ? const Color(0xFFF6D7CF)
          : const Color(0xFFF4E9DD),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        Icon(
          kitchen.alarmRinging ? Icons.alarm_rounded : Icons.timer_outlined,
          color: kitchen.alarmRinging
              ? const Color(0xFFB0412E)
              : const Color(0xFFAA7043),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Text(
            kitchen.alarmRinging ? 'Timer abgelaufen' : 'Küchentimer',
            style: const TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (kitchen.alarmRinging)
          FilledButton(
            onPressed: kitchen.stopAlarm,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB0412E),
            ),
            child: const Text('Alarm aus'),
          )
        else
          Text(
            kitchen.formattedTimer,
            style: const TextStyle(
              color: _ink,
              fontFeatures: [FontFeature.tabularFigures()],
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    ),
  );
}

Future<void> _showTimerDialog(
  BuildContext context,
  KitchenController kitchen,
) async {
  final minutes = await showDialog<int>(
    context: context,
    builder: (_) => const _TimerDialog(),
  );
  if (minutes != null) await kitchen.startTimer(minutes);
}

class _TimerDialog extends StatefulWidget {
  const _TimerDialog();

  @override
  State<_TimerDialog> createState() => _TimerDialogState();
}

class _TimerDialogState extends State<_TimerDialog> {
  final TextEditingController _minutesController = TextEditingController();
  String? _errorText;

  void _startTimer() {
    final minutes = int.tryParse(_minutesController.text);
    if (minutes == null || minutes < 1 || minutes > 240) {
      setState(() {
        _errorText = 'Bitte gib eine Zeit zwischen 1 und 240 Minuten ein.';
      });
      return;
    }
    Navigator.of(context).pop(minutes);
  }

  @override
  void dispose() {
    _minutesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Timer einstellen'),
    content: TextField(
      controller: _minutesController,
      autofocus: true,
      keyboardType: TextInputType.number,
      onChanged: (_) {
        if (_errorText != null) setState(() => _errorText = null);
      },
      decoration: InputDecoration(
        labelText: 'Minuten',
        hintText: 'z. B. 5',
        suffixText: 'Min.',
        errorText: _errorText,
      ),
    ),
    actions: [
      IconButton(
        tooltip: 'Abbrechen',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.close_rounded),
      ),
      IconButton.filled(
        tooltip: 'Timer starten',
        onPressed: _startTimer,
        icon: const Icon(Icons.play_arrow_rounded),
      ),
    ],
  );
}
