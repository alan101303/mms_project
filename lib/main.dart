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

import 'evaluation_log.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => KitchenController()
        ..loadRecipes()
        ..loadVoiceLog()
        ..checkMicPermission(),
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
    home: const _StartGate(),
  );
}

/// Shows the permission screen until the mic is allowed or skipped, and
/// rechecks when the user returns from the system settings.
class _StartGate extends StatefulWidget {
  const _StartGate();

  @override
  State<_StartGate> createState() => _StartGateState();
}

class _StartGateState extends State<_StartGate> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        final kitchen = context.read<KitchenController>();
        if (!(kitchen.micStatus?.isGranted ?? true)) {
          unawaited(kitchen.checkMicPermission());
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Consumer<KitchenController>(
    builder: (context, kitchen, _) => kitchen.needsPermissionScreen
        ? const PermissionPage()
        : const KitchenHomePage(),
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

/// Where the hands-free voice loop currently is.
enum VoiceState { idle, listening, processing, speaking }

/// Non-speech sounds that confirm voice input.
enum UiSound { heard, success, question, error }

enum _VoiceCommand {
  undo,
  help,
  previous,
  repeat,
  hideIngredients,
  ingredients,
  cancelTimer,
  pauseTimer,
  resumeTimer,
  timer,
  pause,
  next,
}

/// Cooking-page buttons that briefly turn green when used by touch or voice.
enum CookingControl { previous, pause, next, repeat, timer, ingredients, undo }

/// Wraps permission_handler, so tests can replace it.
class MicPermission {
  Future<PermissionStatus> status() => Permission.microphone.status;

  Future<PermissionStatus> request() => Permission.microphone.request();

  Future<bool> openSettings() => openAppSettings();
}

/// A voice input while it is being handled, for the evaluation log.
class _Utterance {
  _Utterance(this.startedAt) : lastChangeAt = startedAt;

  final DateTime startedAt;
  DateTime lastChangeAt;
  String text = '';
  double confidence = -1;
  VoiceOutcome? outcome;
  String detail = '';
  int? feedbackMs;
}

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
  KitchenController({
    SoundEffects? sounds,
    MicPermission? permission,
    EvaluationStorage? storage,
  }) : _sounds = sounds ?? SoundEffects(),
       _permission = permission ?? MicPermission(),
       _storage = storage ?? EvaluationStorage();

  static const homeHint = 'Tippe auf das Mikrofon und nenne ein Rezept.';
  static const _minConfidence = 0.35;
  static const _yesWords = {'ja', 'jawohl', 'genau', 'richtig', 'okay', 'ok'};
  static const _noWords = {'nein', 'nee', 'ne', 'nö', 'falsch'};
  static const _fuzzyKeywords = [
    'weiter',
    'nächster',
    'zurück',
    'wiederholen',
    'nochmal',
    'zutaten',
    'timer',
    'pause',
    'stopp',
    'fortsetzen',
    'rückgängig',
    'hilfe',
  ];
  static const _negations = {'nicht', 'kein', 'keine', 'nie'};

  /// Whole words, word stems ending in `*`, or phrases with spaces.
  /// Checked in this order, so earlier commands win.
  static const _commandPatterns = <_VoiceCommand, List<String>>{
    _VoiceCommand.undo: ['rückgängig', 'rueckgaengig', 'undo'],
    _VoiceCommand.help: ['hilfe', 'befehle', 'was kann ich sagen'],
    _VoiceCommand.previous: ['zurück', 'zurueck', 'vorher', 'vorherig*'],
    _VoiceCommand.repeat: [
      'wiederhol*',
      'nochmal',
      'nochmals',
      'noch einmal',
      'noch mal',
    ],
    _VoiceCommand.ingredients: ['zutat*', 'einkauf*', 'was brauche'],
    _VoiceCommand.timer: ['timer', 'wecker'],
    _VoiceCommand.pause: ['pause', 'pausier*', 'stopp*', 'stop', 'anhalten'],
    _VoiceCommand.next: [
      'weiter',
      'fortsetzen',
      'nächst*',
      'naechst*',
      'was kommt danach',
      'was kommt jetzt',
      'und dann',
    ],
  };
  static const _closePatterns = [
    'schließen',
    'schliessen',
    'ausblenden',
    'weg',
    'verstecken',
  ];
  static const _timerPausePatterns = ['pause', 'pausier*', 'anhalten'];
  static const _timerResumePatterns = ['weiter', 'fortsetzen', 'fortfahren'];
  static const _timerStopPatterns = [
    'stopp*',
    'stop',
    'abbrechen',
    'aus',
    'ausschalten',
    'löschen',
    'beenden',
  ];
  static const _helpText =
      'Du kannst sagen: „Weiter“, „Zurück“, „Wiederholen“, „Zutaten“, '
      '„Timer fünf Minuten“, „Timer pausieren“, „Timer stoppen“, „Pause“ '
      'oder „Rückgängig“.';
  static const _maxTimer = Duration(hours: 4);

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final SoundEffects _sounds;
  final MicPermission _permission;
  final EvaluationStorage _storage;
  final List<Recipe> recipes = [];
  final List<VoiceLogEntry> voiceLog = [];
  Timer? _timer;
  Timer? _restartTimer;
  Timer? _alarmTimeout;
  Timer? _highlightTimer;
  _Utterance? _utterance;
  // True while the timer is paused only because „Pause“ paused the guide.
  bool _timerPausedWithGuide = false;
  Completer<void>? _speechDone;
  Future<void> Function(String text, double confidence)? _resultHandler;
  // Reverts the most recent action; each undoable action sets it.
  Future<void> Function()? _undoAction;
  // Last step per recipe, so reopening a recipe continues where it was left.
  final Map<int, int> _progress = {};
  bool _speechInitialized = false;
  bool _ttsConfigured = false;
  bool _heardFeedback = false;
  bool _handlingCommand = false;
  int _speechToken = 0;
  String? _pendingCommand;
  int _recipeIndex = 0;
  int stepIndex = 0;
  int timerSeconds = 0;
  bool timerPaused = false;
  bool handsFree = false;
  bool alarmRinging = false;
  VoiceState voiceState = VoiceState.idle;
  bool isPaused = false;
  bool isLoading = true;
  String recognizedText = '';
  String feedback = homeHint;
  String? pendingLabel;
  CookingControl? highlightedControl;
  // Null until checked at startup.
  PermissionStatus? micStatus;
  bool voiceSkipped = false;

  Recipe? get recipe => recipes.isEmpty ? null : recipes[_recipeIndex];
  bool get needsPermissionScreen =>
      !voiceSkipped && micStatus != null && !micStatus!.isGranted;
  bool get canUndo => _undoAction != null;
  bool get isListening => voiceState == VoiceState.listening;

  String get voiceStatus => switch (voiceState) {
    VoiceState.listening => 'Ich höre zu …',
    VoiceState.processing => 'Verarbeite …',
    VoiceState.speaking => 'Ich spreche …',
    VoiceState.idle => handsFree ? 'Gleich wieder bereit …' : 'Mikrofon aus',
  };

  Future<void> checkMicPermission() async {
    try {
      micStatus = await _permission.status();
    } catch (_) {
      micStatus = PermissionStatus.denied;
    }
    notifyListeners();
  }

  Future<void> requestMicPermission() async {
    try {
      micStatus = await _permission.request();
    } catch (_) {
      micStatus = PermissionStatus.denied;
    }
    if (micStatus!.isPermanentlyDenied) {
      feedback = 'Mikrofonzugriff fehlt. Bitte erlaube ihn in den Einstellungen.';
    }
    notifyListeners();
  }

  Future<void> openMicSettings() async {
    try {
      await _permission.openSettings();
    } catch (_) {
      // Without a settings app there's nothing more to offer.
    }
  }

  /// Uses the app by touch only; the mic can still be allowed later.
  void skipVoiceSetup() {
    voiceSkipped = true;
    notifyListeners();
  }

  Future<void> loadVoiceLog() async {
    voiceLog
      ..clear()
      ..addAll(await _storage.load());
    notifyListeners();
  }

  /// Marks an entry as correctly or wrongly recognized; the same mark again
  /// removes it.
  void markLogEntry(VoiceLogEntry entry, bool correct) {
    entry.correct = entry.correct == correct ? null : correct;
    notifyListeners();
    unawaited(_storage.save(voiceLog));
  }

  void clearVoiceLog() {
    voiceLog.clear();
    notifyListeners();
    unawaited(_storage.save(voiceLog));
  }

  Future<String?> exportVoiceLog() => _storage.exportCsv(voiceLog);

  /// Plays the confirmation sound for a voice input and records how it was
  /// handled and how quickly, for the evaluation log.
  void _confirmInput(UiSound sound, VoiceOutcome outcome, String detail) {
    unawaited(_sounds.play(sound));
    final utterance = _utterance;
    if (utterance == null || utterance.outcome != null) return;
    utterance
      ..outcome = outcome
      ..detail = detail
      ..feedbackMs = DateTime.now()
          .difference(utterance.lastChangeAt)
          .inMilliseconds;
  }

  void _logUtterance(_Utterance utterance) {
    final outcome = utterance.outcome;
    if (outcome == null) return;
    voiceLog.add(
      VoiceLogEntry(
        time: utterance.startedAt,
        text: utterance.text,
        confidence: utterance.confidence,
        outcome: outcome,
        detail: utterance.detail,
        feedbackMs: utterance.feedbackMs,
      ),
    );
    unawaited(_storage.save(voiceLog));
  }

  void _highlight(CookingControl control) {
    highlightedControl = control;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 800), () {
      highlightedControl = null;
      notifyListeners();
    });
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

    PermissionStatus granted;
    try {
      granted = await _permission.request();
    } catch (_) {
      granted = PermissionStatus.denied;
    }
    // Keep the status in sync, without showing the permission screen again.
    micStatus = granted;
    voiceSkipped = true;
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
    _utterance = null;
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
    final now = DateTime.now();
    final utterance = _utterance ??= _Utterance(now);
    if (utterance.text != recognizedText) {
      utterance
        ..text = recognizedText
        ..lastChangeAt = now;
    }
    if (!_heardFeedback) {
      _heardFeedback = true;
      unawaited(_sounds.play(UiSound.heard));
    }
    if (result.finalResult) {
      utterance.confidence = result.confidence;
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
      final utterance = _utterance;
      _utterance = null;
      if (utterance != null) _logUtterance(utterance);
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
      'Die Spracherkennung wurde unterbrochen. '
          'Tippe auf das Mikrofon, um sie neu zu starten.',
  };

  Future<bool> selectRecipeFromSpeech(String text, double confidence) async {
    recognizedText = text;
    final normalized = text.toLowerCase().trim();

    if (confidence > 0 && confidence < _minConfidence) {
      _confirmInput(UiSound.question, VoiceOutcome.question, 'Rezeptname');
      feedback =
          'Ich bin nicht sicher. Bitte sage den Rezeptnamen noch einmal.';
      notifyListeners();
      await _speak(feedback);
      return false;
    }

    final index = _findRecipeIndex(normalized);
    if (index == null) {
      _confirmInput(UiSound.error, VoiceOutcome.notUnderstood, '');
      feedback = 'Ich habe das Rezept nicht erkannt. Sage zum Beispiel „Cremige Tomatenpasta“.';
      notifyListeners();
      await _speak(feedback);
      return false;
    }

    _confirmInput(UiSound.success, VoiceOutcome.recipe, recipes[index].name);
    openRecipe(index);
    feedback = '${recipes[index].name} ausgewählt.';
    notifyListeners();
    return true;
  }

  /// Spoken confirmation after a recipe was chosen by voice.
  Future<void> announceRecipe() async {
    final current = recipe;
    if (current == null) return;
    final resumeHint = stepIndex > 0
        ? ' Du warst bei Schritt ${stepIndex + 1}.'
        : '';
    await _speak(
      '${current.name}.$resumeHint Sag „Weiter“, wenn du bereit bist.',
    );
  }

  Future<void> undo() async {
    _highlight(CookingControl.undo);
    final action = _undoAction;
    if (action == null) {
      feedback = 'Es gibt nichts rückgängig zu machen.';
      notifyListeners();
      await _speak(feedback);
      return;
    }
    _undoAction = null;
    await action();
  }

  /// Remembers the recipe and step, so undo can return to them.
  void _saveStepUndo() {
    final recipeIndex = _recipeIndex;
    final step = stepIndex;
    final paused = isPaused;
    _undoAction = () async {
      _recipeIndex = recipeIndex;
      stepIndex = step;
      isPaused = paused;
      feedback = 'Letzte Aktion rückgängig gemacht.';
      notifyListeners();
      if (isPaused) {
        await _tts.stop();
      } else {
        await _readCurrentStep();
      }
    };
  }

  /// Remembers the timer, so undo can bring it back. A running timer is
  /// restored with the time it would have left by now.
  void _saveTimerUndo() {
    final seconds = timerSeconds;
    final paused = timerPaused;
    final savedAt = DateTime.now();
    _undoAction = () async {
      final elapsed = paused ? 0 : DateTime.now().difference(savedAt).inSeconds;
      _setTimer(max(0, seconds - elapsed), paused: paused);
      feedback = timerSeconds > 0
          ? 'Vorheriger Timer wiederhergestellt.'
          : 'Timer entfernt.';
      notifyListeners();
    };
  }

  /// Switches recipes, keeping each recipe's last step.
  void _switchRecipe(int index) {
    _progress[_recipeIndex] = stepIndex;
    _recipeIndex = index;
    stepIndex = _progress[index] ?? 0;
    ingredientsVisible = false;
  }

  /// Continues the guide and a timer that „Pause“ stopped together with it.
  /// A timer paused on its own („Timer pausieren“) stays paused.
  void _resumeGuide() {
    isPaused = false;
    if (timerPaused && _timerPausedWithGuide) _setTimer(timerSeconds);
  }

  Future<void> selectRecipe(int index) async {
    if (index < 0 || index >= recipes.length || index == _recipeIndex) return;
    _saveStepUndo();
    _switchRecipe(index);
    _resumeGuide();
    feedback = '${recipes[index].name} ausgewählt.';
    notifyListeners();
    await _readCurrentStep();
  }

  void openRecipe(int index) {
    if (index < 0 || index >= recipes.length) return;
    _switchRecipe(index);
    isPaused = true;
    // A freshly opened recipe has nothing to undo yet.
    _undoAction = null;
    // From here on, voice input is handled as cooking commands.
    _resultHandler = null;
    feedback = stepIndex > 0
        ? 'Du warst bei Schritt ${stepIndex + 1}. Sag „Weiter“ oder tippe '
              'auf Start, um dort weiterzumachen.'
        : 'Sag „Weiter“ oder tippe auf Start, wenn du bereit bist.';
    notifyListeners();
  }

  Future<void> nextStep() async {
    final current = recipe;
    if (current == null) return;
    _highlight(CookingControl.next);
    if (stepIndex >= current.steps.length - 1) {
      feedback = 'Das war der letzte Schritt. Guten Appetit!';
      notifyListeners();
      await _speak(feedback);
      return;
    }
    _saveStepUndo();
    stepIndex++;
    _resumeGuide();
    feedback = 'Schritt ${stepIndex + 1} von ${current.steps.length}';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> previousStep() async {
    _highlight(CookingControl.previous);
    if (stepIndex == 0) {
      feedback = 'Du bist schon beim ersten Schritt.';
      notifyListeners();
      return;
    }
    _saveStepUndo();
    stepIndex--;
    _resumeGuide();
    feedback = 'Schritt ${stepIndex + 1} von ${recipe!.steps.length}';
    notifyListeners();
    await _readCurrentStep();
  }

  Future<void> repeatStep() async {
    _highlight(CookingControl.repeat);
    _resumeGuide();
    feedback = 'Ich wiederhole den Schritt.';
    notifyListeners();
    await _readCurrentStep();
  }

  /// „Pause“ stops both the reading and a running timer; „Weiter“ resumes both.
  Future<void> togglePause() async {
    _highlight(CookingControl.pause);
    final wasPaused = isPaused;
    _undoAction = () => _setPaused(wasPaused);
    await _setPaused(!wasPaused);
  }

  Future<void> _setPaused(bool paused) async {
    if (paused) {
      isPaused = true;
      if (timerSeconds > 0 && !timerPaused) {
        _setTimer(timerSeconds, paused: true);
        _timerPausedWithGuide = true;
      }
      feedback = timerPaused
          ? 'Anleitung und Timer pausiert.'
          : 'Anleitung pausiert.';
      notifyListeners();
      await _tts.stop();
    } else {
      _resumeGuide();
      feedback = 'Weiter geht’s.';
      notifyListeners();
      await _readCurrentStep();
    }
  }

  void showIngredients() {
    _highlight(CookingControl.ingredients);
    ingredientsVisible = true;
    feedback = 'Zutaten für ${recipe?.name ?? 'das Rezept'}';
    notifyListeners();
  }

  void hideIngredients() {
    _highlight(CookingControl.ingredients);
    ingredientsVisible = false;
    feedback = 'Zutaten ausgeblendet.';
    notifyListeners();
  }

  bool ingredientsVisible = false;

  Future<void> startTimer(Duration duration) async {
    if (duration < const Duration(seconds: 1) || duration > _maxTimer) {
      feedback = 'Bitte nenne eine Zeit zwischen einer Sekunde und vier Stunden.';
      notifyListeners();
      await _speak(feedback);
      return;
    }
    await stopAlarm();
    _highlight(CookingControl.timer);
    _saveTimerUndo();
    _setTimer(duration.inSeconds);
    feedback = 'Timer auf ${_describeDuration(duration)} gestellt.';
    notifyListeners();
    await _speak(feedback);
  }

  Future<void> cancelTimer() async {
    if (timerSeconds == 0) {
      feedback = 'Es läuft gerade kein Timer.';
      notifyListeners();
      await _speak(feedback);
      return;
    }
    _highlight(CookingControl.timer);
    _saveTimerUndo();
    _setTimer(0);
    feedback = 'Timer gestoppt.';
    notifyListeners();
    await _speak(feedback);
  }

  Future<void> toggleTimerPause() => timerPaused ? resumeTimer() : pauseTimer();

  /// Pauses only the timer; the guide keeps going.
  Future<void> pauseTimer() async {
    if (timerSeconds == 0 || timerPaused) {
      feedback = timerSeconds == 0
          ? 'Es läuft gerade kein Timer.'
          : 'Der Timer ist schon pausiert.';
      notifyListeners();
      await _speak(feedback);
      return;
    }
    _highlight(CookingControl.timer);
    _saveTimerUndo();
    _setTimer(timerSeconds, paused: true);
    feedback = 'Timer pausiert bei $formattedTimer.';
    notifyListeners();
    await _speak('Timer pausiert.');
  }

  Future<void> resumeTimer() async {
    if (!timerPaused) {
      feedback = timerSeconds == 0
          ? 'Es läuft gerade kein Timer.'
          : 'Der Timer läuft bereits.';
      notifyListeners();
      await _speak(feedback);
      return;
    }
    _highlight(CookingControl.timer);
    _saveTimerUndo();
    _setTimer(timerSeconds);
    feedback = 'Timer läuft weiter.';
    notifyListeners();
    await _speak(feedback);
  }

  void _setTimer(int seconds, {bool paused = false}) {
    _timer?.cancel();
    _timerPausedWithGuide = false;
    timerSeconds = seconds;
    timerPaused = seconds > 0 && paused;
    if (seconds > 0 && !paused) _startTimerTicker();
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
      _confirmInput(UiSound.success, VoiceOutcome.command, 'Alarm aus');
      await stopAlarm();
      return;
    }

    if (_pendingCommand != null) {
      if (_words(command).any(_yesWords.contains)) {
        _confirmInput(UiSound.success, VoiceOutcome.answer, 'Ja');
        return answerPending(yes: true);
      }
      if (_words(command).any(_noWords.contains)) {
        _confirmInput(UiSound.success, VoiceOutcome.answer, 'Nein');
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
      final label = _commandLabel(type, command);
      if (lowConfidence) return _askToConfirm(command, label);
      _confirmInput(UiSound.success, VoiceOutcome.command, label);
      return _runCommand(type, command);
    }

    final recipeIndex = _findRecipeIndex(command);
    if (recipeIndex != null) {
      final name = recipes[recipeIndex].name;
      if (lowConfidence) return _askToConfirm(command, name);
      _confirmInput(UiSound.success, VoiceOutcome.recipe, name);
      return selectRecipe(recipeIndex);
    }

    final corrected = _fuzzyCorrect(command);
    if (corrected != null) {
      final guess = _detectCommand(corrected);
      if (guess != null) {
        return _askToConfirm(corrected, _commandLabel(guess, corrected));
      }
    }

    _confirmInput(UiSound.error, VoiceOutcome.notUnderstood, '');
    feedback = 'Das habe ich nicht verstanden. Sag zum Beispiel „Weiter“, '
        '„Timer fünf Minuten“ oder „Hilfe“ für alle Befehle.';
    notifyListeners();
    await _speak(feedback);
  }

  Future<void> _askToConfirm(String command, String label) async {
    _pendingCommand = command;
    pendingLabel = label;
    _confirmInput(UiSound.question, VoiceOutcome.question, label);
    feedback = 'Meintest du „$label“? Sag „Ja“ oder „Nein“.';
    notifyListeners();
    await _speak(feedback);
  }

  void _clearPending() {
    _pendingCommand = null;
    pendingLabel = null;
  }

  static _VoiceCommand? _detectCommand(String command) {
    final words = _words(command).toList();
    final timerPatterns = _commandPatterns[_VoiceCommand.timer]!;
    if (_mentions(words, timerPatterns)) {
      if (_mentions(words, _timerStopPatterns)) return _VoiceCommand.cancelTimer;
      if (_mentions(words, _timerPausePatterns)) return _VoiceCommand.pauseTimer;
      // „Timer weiter“ resumes; „Timer weiter auf 5 Minuten“ sets a new time.
      if (_mentions(words, _timerResumePatterns) &&
          _parseDuration(command) == null) {
        return _VoiceCommand.resumeTimer;
      }
    }
    if (_mentions(words, _commandPatterns[_VoiceCommand.ingredients]!) &&
        _mentions(words, _closePatterns)) {
      return _VoiceCommand.hideIngredients;
    }
    for (final MapEntry(key: type, value: patterns)
        in _commandPatterns.entries) {
      if (_mentions(words, patterns)) return type;
    }
    return null;
  }

  /// Whether a pattern from [_commandPatterns] occurs as a whole word.
  /// A negated word („nicht weiter“) doesn't count.
  static bool _mentions(List<String> words, List<String> patterns) {
    final text = ' ${words.join(' ')} ';
    for (final pattern in patterns) {
      if (pattern.contains(' ')) {
        if (text.contains(' $pattern ')) return true;
        continue;
      }
      final isStem = pattern.endsWith('*');
      final key = isStem ? pattern.substring(0, pattern.length - 1) : pattern;
      for (var i = 0; i < words.length; i++) {
        final matches = isStem ? words[i].startsWith(key) : words[i] == key;
        if (matches && (i == 0 || !_negations.contains(words[i - 1]))) {
          return true;
        }
      }
    }
    return false;
  }

  String _commandLabel(_VoiceCommand type, String command) => switch (type) {
    _VoiceCommand.undo => 'Rückgängig',
    _VoiceCommand.help => 'Hilfe',
    _VoiceCommand.previous => 'Zurück',
    _VoiceCommand.repeat => 'Wiederholen',
    _VoiceCommand.ingredients => 'Zutaten',
    _VoiceCommand.hideIngredients => 'Zutaten schließen',
    _VoiceCommand.cancelTimer => 'Timer stoppen',
    _VoiceCommand.pauseTimer => 'Timer pausieren',
    _VoiceCommand.resumeTimer => 'Timer fortsetzen',
    _VoiceCommand.timer => switch (_parseDuration(command)) {
      final duration? => 'Timer ${_describeDuration(duration)}',
      null => 'Timer',
    },
    _VoiceCommand.pause => 'Pause',
    _VoiceCommand.next => 'Weiter',
  };

  Future<void> _runCommand(_VoiceCommand type, String command) async {
    switch (type) {
      case _VoiceCommand.undo:
        await undo();
      case _VoiceCommand.help:
        feedback = _helpText;
        notifyListeners();
        await _speak(feedback);
      case _VoiceCommand.cancelTimer:
        await cancelTimer();
      case _VoiceCommand.pauseTimer:
        await pauseTimer();
      case _VoiceCommand.resumeTimer:
        await resumeTimer();
      case _VoiceCommand.hideIngredients:
        hideIngredients();
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
        final duration = _parseDuration(command);
        if (duration == null) {
          feedback = 'Wie lange soll der Timer laufen? '
              'Sag zum Beispiel „Timer fünf Minuten“.';
          notifyListeners();
          await _speak(feedback);
        } else {
          await startTimer(duration);
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

  static const _ordinals = {
    'eins': 1,
    'erste': 1,
    'erstes': 1,
    'ersten': 1,
    'zwei': 2,
    'zweite': 2,
    'zweites': 2,
    'zweiten': 2,
    'drei': 3,
    'dritte': 3,
    'drittes': 3,
    'dritten': 3,
  };

  /// Finds a recipe by number („Rezept zwei“, „das dritte Rezept“) or by its
  /// name or part of it („Tomatenpasta“, „Pfannkuchen“).
  int? _findRecipeIndex(String command) {
    final words = _words(command).toList();
    for (var i = 0; i < words.length; i++) {
      final number = int.tryParse(words[i]) ?? _ordinals[words[i]];
      if (number == null || number < 1 || number > recipes.length) continue;
      final before = i > 0 ? words[i - 1] : '';
      final after = i + 1 < words.length ? words[i + 1] : '';
      if (before == 'rezept' || before == 'nummer' || after == 'rezept') {
        return number - 1;
      }
    }

    // Score each recipe by how much of the spoken text appears in its name;
    // short words like „die“ or „ofen“ are too ambiguous to count.
    int? best;
    var bestScore = 0;
    var tied = false;
    for (var index = 0; index < recipes.length; index++) {
      final nameWords = _words(recipes[index].name.toLowerCase()).toList();
      var score = 0;
      for (final word in words) {
        if (word.length >= 5 && nameWords.any((name) => name.contains(word))) {
          score += word.length;
        }
      }
      if (score > bestScore) {
        best = index;
        bestScore = score;
        tied = false;
      } else if (score > 0 && score == bestScore) {
        tied = true;
      }
    }
    return tied ? null : best;
  }

  static const _durationUnits = {
    'sekunde': 1,
    'sekunden': 1,
    'sek': 1,
    'minute': 60,
    'minuten': 60,
    'min': 60,
    'stunde': 3600,
    'stunden': 3600,
    'std': 3600,
  };
  static const _halfWords = {'halb', 'halbe', 'halben'};
  // Articles count as „one“ before a unit („eine Stunde“), but not alone:
  // „Stell einen Timer“ has no duration.
  static const _articles = {'ein', 'eine', 'einen', 'einer'};
  static const _ones = {
    'ein': 1,
    'eins': 1,
    'eine': 1,
    'einen': 1,
    'einer': 1,
    'zwei': 2,
    'zwo': 2,
    'drei': 3,
    'vier': 4,
    'fünf': 5,
    'fuenf': 5,
    'sechs': 6,
    'sieben': 7,
    'acht': 8,
    'neun': 9,
  };
  static const _teens = {
    'zehn': 10,
    'elf': 11,
    'zwölf': 12,
    'zwoelf': 12,
    'dreizehn': 13,
    'vierzehn': 14,
    'fünfzehn': 15,
    'fuenfzehn': 15,
    'sechzehn': 16,
    'siebzehn': 17,
    'achtzehn': 18,
    'neunzehn': 19,
  };
  static const _tens = {
    'zwanzig': 20,
    'dreißig': 30,
    'dreissig': 30,
    'vierzig': 40,
    'fünfzig': 50,
    'fuenfzig': 50,
    'sechzig': 60,
    'siebzig': 70,
    'achtzig': 80,
    'neunzig': 90,
  };

  /// Reads a duration such as „fünf Minuten“, „eine halbe Stunde“,
  /// „1 Minute 30 Sekunden“, „anderthalb Stunden“ or just „zehn“ (minutes).
  static Duration? _parseDuration(String command) {
    final tokens = RegExp(r'\d+(?:[.,]\d+)?|[a-zäöüß]+')
        .allMatches(command)
        .map((match) => match.group(0)!)
        .toList();
    var seconds = 0.0;
    var hasUnit = false;
    double? looseNumber;
    for (var i = 0; i < tokens.length; i++) {
      final unit = _durationUnits[tokens[i]];
      if (unit == null) {
        if (!_articles.contains(tokens[i])) {
          looseNumber = _parseNumber(tokens[i]) ?? looseNumber;
        }
        continue;
      }
      final before = i > 0 ? tokens[i - 1] : '';
      final amount = _halfWords.contains(before) ? 0.5 : _parseNumber(before);
      if (amount != null) {
        seconds += amount * unit;
        hasUnit = true;
      }
    }
    if (!hasUnit && looseNumber != null) seconds = looseNumber * 60;
    final total = seconds.round();
    return total > 0 ? Duration(seconds: total) : null;
  }

  static double? _parseNumber(String word) {
    final digits = double.tryParse(word.replaceAll(',', '.'));
    if (digits != null) return digits;
    if (word == 'anderthalb') return 1.5;
    if (word.endsWith('einhalb') && word.length > 'einhalb'.length) {
      final whole = _parseInteger(word.substring(0, word.length - 7));
      return whole == null ? null : whole + 0.5;
    }
    return _parseInteger(word)?.toDouble();
  }

  /// German number words up to 999, e.g. „fünfundzwanzig“, „hundertzwanzig“.
  static int? _parseInteger(String word) {
    var rest = word;
    var total = 0;
    final hundred = rest.indexOf('hundert');
    if (hundred >= 0) {
      final prefix = rest.substring(0, hundred);
      final hundreds = prefix.isEmpty ? 1 : _ones[prefix];
      if (hundreds == null) return null;
      total = hundreds * 100;
      rest = rest.substring(hundred + 'hundert'.length);
      if (rest.startsWith('und')) rest = rest.substring(3);
      if (rest.isEmpty) return total;
    }
    final direct = _ones[rest] ?? _teens[rest] ?? _tens[rest];
    if (direct != null) return total + direct;
    final und = rest.indexOf('und');
    if (und > 0) {
      final one = _ones[rest.substring(0, und)];
      final ten = _tens[rest.substring(und + 3)];
      if (one != null && ten != null) return total + one + ten;
    }
    return null;
  }

  static String _describeDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    return [
      if (hours > 0) '$hours ${hours == 1 ? 'Stunde' : 'Stunden'}',
      if (minutes > 0) '$minutes ${minutes == 1 ? 'Minute' : 'Minuten'}',
      if (seconds > 0) '$seconds ${seconds == 1 ? 'Sekunde' : 'Sekunden'}',
    ].join(' ');
  }

  String get formattedTimer {
    final hours = timerSeconds ~/ 3600;
    final minutes = (timerSeconds ~/ 60 % 60).toString().padLeft(2, '0');
    final seconds = (timerSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _restartTimer?.cancel();
    _alarmTimeout?.cancel();
    _highlightTimer?.cancel();
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
                          tooltip: 'Auswertung',
                          onPressed: () {
                            unawaited(kitchen.stopVoice());
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const EvaluationPage(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.analytics_outlined),
                          color: _green,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
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
              _SettingsLink(kitchen: kitchen),
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

/// Shortcut to the system settings once the mic was permanently denied.
class _SettingsLink extends StatelessWidget {
  const _SettingsLink({required this.kitchen});

  final KitchenController kitchen;

  @override
  Widget build(BuildContext context) =>
      (kitchen.micStatus?.isPermanentlyDenied ?? false)
      ? TextButton.icon(
          onPressed: kitchen.openMicSettings,
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('Einstellungen öffnen'),
        )
      : const SizedBox.shrink();
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
      'Sage den Rezeptnamen oder einen Teil davon, zum Beispiel '
          '„Tomatenpasta“, oder „Rezept zwei“.',
    ),
    (
      Icons.arrow_forward_rounded,
      'Weiter',
      'Zum nächsten Zubereitungsschritt. Auch: „Nächster Schritt“.',
    ),
    (Icons.arrow_back_rounded, 'Zurück', 'Zum vorherigen Zubereitungsschritt.'),
    (
      Icons.replay_rounded,
      'Nochmal',
      'Liest den aktuellen Schritt erneut vor. Auch: „Wiederholen“.',
    ),
    (
      Icons.menu_book_rounded,
      'Zutaten',
      'Zeigt die Zutaten des ausgewählten Rezepts. „Zutaten schließen“ '
          'blendet sie wieder aus.',
    ),
    (
      Icons.timer_outlined,
      'Timer fünf Minuten',
      'Startet einen Timer, auch mit Sekunden oder Stunden, zum Beispiel '
          '„Timer eine halbe Stunde“. Höchstens vier Stunden.',
    ),
    (
      Icons.timer_off_outlined,
      'Timer stoppen',
      'Beendet den laufenden Timer. „Timer pausieren“ hält ihn an, '
          '„Timer fortsetzen“ lässt ihn weiterlaufen.',
    ),
    (
      Icons.pause_rounded,
      'Pause',
      'Pausiert die Anleitung und den Timer. Mit „Weiter“ geht es weiter.',
    ),
    (
      Icons.undo_rounded,
      'Rückgängig',
      'Macht die letzte Aktion rückgängig.',
    ),
    (
      Icons.help_outline_rounded,
      'Hilfe',
      'Liest die wichtigsten Befehle vor.',
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
        const Text(
          'Mikrofon-Status',
          style: TextStyle(
            color: _ink,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        const _MicStatusRow(
          color: _micOn,
          icon: Icons.mic,
          text: 'Grünes Mikrofon: Die App hört zu.',
        ),
        const _MicStatusRow(
          color: _micOff,
          icon: Icons.mic_none_rounded,
          text: 'Graues Mikrofon: Die App hört gerade nicht zu.',
        ),
        const _MicStatusRow(
          color: _micOff,
          icon: Icons.volume_up_rounded,
          text: 'Lautsprecher: Die App spricht und hört danach wieder zu.',
        ),
        const _MicStatusRow(
          color: _micOff,
          icon: Icons.mic_off_rounded,
          text: 'Durchgestrichen: Sprachsteuerung aus. Tippe auf das Mikrofon, '
              'um sie einzuschalten.',
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

class _MicStatusRow extends StatelessWidget {
  const _MicStatusRow({
    required this.color,
    required this.icon,
    required this.text,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: color,
          foregroundColor: Colors.white,
          child: Icon(icon, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: _ink, fontSize: 13, height: 1.4),
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
                      style: kitchen.highlightedControl == CookingControl.undo
                          ? IconButton.styleFrom(
                              backgroundColor: _micOn,
                              foregroundColor: Colors.white,
                            )
                          : null,
                    ),
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
                      _InlineIngredients(
                        recipe: recipe,
                        onClose: kitchen.hideIngredients,
                      ),
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
        highlighted: kitchen.highlightedControl == CookingControl.previous,
      ),
      _IconControl(
        icon: kitchen.isPaused ? Icons.play_arrow_rounded : Icons.stop_rounded,
        label: kitchen.isPaused ? 'Anleitung starten' : 'Anleitung stoppen',
        prominent: true,
        onPressed: kitchen.togglePause,
        highlighted: kitchen.highlightedControl == CookingControl.pause,
      ),
      _IconControl(
        icon: Icons.arrow_forward_rounded,
        label: 'Nächster Schritt',
        onPressed: kitchen.nextStep,
        highlighted: kitchen.highlightedControl == CookingControl.next,
      ),
      _IconControl(
        icon: Icons.replay_rounded,
        label: 'Schritt wiederholen',
        onPressed: kitchen.repeatStep,
        highlighted: kitchen.highlightedControl == CookingControl.repeat,
      ),
      _IconControl(
        icon: Icons.timer_outlined,
        label: 'Timer einstellen',
        onPressed: () => _showTimerDialog(context, kitchen),
        highlighted: kitchen.highlightedControl == CookingControl.timer,
      ),
      _IconControl(
        icon: Icons.menu_book_rounded,
        label: kitchen.ingredientsVisible
            ? 'Zutaten ausblenden'
            : 'Zutaten anzeigen',
        onPressed: kitchen.ingredientsVisible
            ? kitchen.hideIngredients
            : kitchen.showIngredients,
        highlighted: kitchen.highlightedControl == CookingControl.ingredients,
      ),
    ],
  );
}

class _IconControl extends StatelessWidget {
  const _IconControl({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.highlighted,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool prominent;

  /// Briefly true after the action ran, by touch or by voice.
  final bool highlighted;

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
          backgroundColor: highlighted
              ? _micOn
              : prominent
              ? _green
              : Colors.white,
          foregroundColor: highlighted || prominent ? Colors.white : _ink,
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
        _SettingsLink(kitchen: kitchen),
      ],
    ),
  );
}

class _InlineIngredients extends StatelessWidget {
  const _InlineIngredients({required this.recipe, required this.onClose});

  final Recipe recipe;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(18, 8, 8, 18),
    decoration: BoxDecoration(
      color: const Color(0xFFE9EDE3),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Zutaten für ${recipe.name}',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Zutaten schließen',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
              color: _ink,
            ),
          ],
        ),
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
            kitchen.alarmRinging
                ? 'Timer abgelaufen'
                : kitchen.timerPaused
                ? 'Küchentimer (pausiert)'
                : 'Küchentimer',
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
        else ...[
          Text(
            kitchen.formattedTimer,
            style: const TextStyle(
              color: _ink,
              fontFeatures: [FontFeature.tabularFigures()],
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: kitchen.timerPaused ? 'Timer fortsetzen' : 'Timer pausieren',
            onPressed: kitchen.toggleTimerPause,
            icon: Icon(
              kitchen.timerPaused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
            ),
            color: _ink,
          ),
          IconButton(
            tooltip: 'Timer stoppen',
            onPressed: kitchen.cancelTimer,
            icon: const Icon(Icons.stop_rounded),
            color: _ink,
          ),
        ],
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
  if (minutes != null) await kitchen.startTimer(Duration(minutes: minutes));
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

/// Screen 1 of the proposal: explains the mic before Android asks for it.
class PermissionPage extends StatelessWidget {
  const PermissionPage({super.key});

  static const _points = <(IconData, String)>[
    (
      Icons.mic,
      'Das Mikrofon ist nur aktiv, wenn das Mikrofon-Symbol grün ist.',
    ),
    (
      Icons.cloud_outlined,
      'Die Erkennung nutzt die Spracherkennung deines Geräts und braucht '
          'meist eine Internetverbindung.',
    ),
    (
      Icons.touch_app_outlined,
      'Alles lässt sich auch per Touch bedienen.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Consumer<KitchenController>(
    builder: (context, kitchen, _) {
      final denied = kitchen.micStatus?.isPermanentlyDenied ?? false;
      return Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
            children: [
              const CircleAvatar(
                radius: 40,
                backgroundColor: Color(0xFFE7EBDD),
                foregroundColor: _green,
                child: Icon(Icons.mic, size: 40),
              ),
              const SizedBox(height: 24),
              const Text(
                'Sprachsteuerung erlauben',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _ink,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Küchenstimme hört auf Befehle wie „Weiter“ oder „Timer fünf '
                'Minuten“, damit du das Display mit nassen Händen nicht '
                'berühren musst. Dafür braucht die App Zugriff auf das '
                'Mikrofon.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _ink, fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: 24),
              for (final (icon, text) in _points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Icon(icon, color: _green),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          text,
                          style: const TextStyle(
                            color: Color(0xFF59645A),
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              if (denied) ...[
                const Text(
                  'Der Mikrofonzugriff wurde abgelehnt. Du kannst ihn in den '
                  'Einstellungen unter „Berechtigungen“ erlauben.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFB0412E), fontSize: 14),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: kitchen.openMicSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Einstellungen öffnen'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: kitchen.requestMicPermission,
                  icon: const Icon(Icons.mic),
                  label: const Text('Mikrofon freigeben'),
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: kitchen.skipVoiceSetup,
                child: const Text('Ohne Sprache fortfahren'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// AP8: recognition rate and feedback times of the logged voice inputs.
class EvaluationPage extends StatelessWidget {
  const EvaluationPage({super.key});

  static String _percent(int part, int whole) =>
      whole == 0 ? '–' : '${(100 * part / whole).round()} %';

  static String _time(DateTime time) => [
    time.hour,
    time.minute,
    time.second,
  ].map((part) => part.toString().padLeft(2, '0')).join(':');

  Future<void> _export(BuildContext context, KitchenController kitchen) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await kitchen.exportVoiceLog();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          path == null ? 'Export fehlgeschlagen.' : 'Gespeichert unter $path',
        ),
      ),
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    KitchenController kitchen,
  ) async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Protokoll löschen?'),
        content: const Text('Alle aufgezeichneten Spracheingaben gehen verloren.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (clear ?? false) kitchen.clearVoiceLog();
  }

  @override
  Widget build(BuildContext context) => Consumer<KitchenController>(
    builder: (context, kitchen, _) {
      final summary = VoiceLogSummary.of(kitchen.voiceLog);
      final rows = <(String, String)>[
        ('Spracheingaben', '${summary.total}'),
        (
          'Direkt ausgeführt',
          '${summary.executed} (${_percent(summary.executed, summary.total)})',
        ),
        (
          'Rückfragen',
          '${summary.questions} (${_percent(summary.questions, summary.total)})',
        ),
        (
          'Nicht verstanden',
          '${summary.notUnderstood} '
              '(${_percent(summary.notUnderstood, summary.total)})',
        ),
        (
          'Erkennungsrate (markiert)',
          '${summary.markedCorrect} von ${summary.marked} '
              '(${_percent(summary.markedCorrect, summary.marked)})',
        ),
        (
          'Rückmeldung unter 1 s',
          '${summary.underOneSecond} von ${summary.timed} '
              '(${_percent(summary.underOneSecond, summary.timed)})',
        ),
        (
          'Rückmeldezeit Median / Max',
          summary.medianMs == null
              ? '–'
              : '${summary.medianMs} ms / ${summary.maxMs} ms',
        ),
      ];

      return Scaffold(
        appBar: AppBar(
          title: const Text('Auswertung'),
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
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Column(
                children: [
                  for (final (label, value) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(
                                color: Color(0xFF59645A),
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Text(
                            value,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Markiere jede Eingabe als richtig (✓) oder falsch (✗) erkannt, '
              'um die Erkennungsrate zu berechnen. Die Rückmeldezeit misst '
              'vom letzten erkannten Wort bis zum Bestätigungston.',
              style: TextStyle(
                color: Color(0xFF59645A),
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: kitchen.voiceLog.isEmpty
                        ? null
                        : () => _export(context, kitchen),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('CSV exportieren'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: kitchen.voiceLog.isEmpty
                      ? null
                      : () => _confirmClear(context, kitchen),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Löschen'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (kitchen.voiceLog.isEmpty)
              const Text(
                'Noch keine Spracheingaben. Schalte in der Kochansicht das '
                'Mikrofon ein und sprich Befehle.',
                style: TextStyle(color: Color(0xFF59645A), fontSize: 13),
              ),
            for (final entry in kitchen.voiceLog.reversed)
              Card(
                elevation: 0,
                color: Colors.white,
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '„${entry.text}“',
                              style: const TextStyle(
                                color: _ink,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              [
                                _time(entry.time),
                                entry.detail.isEmpty
                                    ? entry.outcome.label
                                    : '${entry.outcome.label}: ${entry.detail}',
                                if (entry.feedbackMs != null)
                                  '${entry.feedbackMs} ms',
                                if (entry.confidence >= 0)
                                  'Konfidenz ${entry.confidence.toStringAsFixed(2)}',
                              ].join(' · '),
                              style: const TextStyle(
                                color: Color(0xFF59645A),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Richtig erkannt',
                        onPressed: () => kitchen.markLogEntry(entry, true),
                        icon: const Icon(Icons.check_rounded),
                        color: entry.correct == true ? Colors.white : _ink,
                        style: IconButton.styleFrom(
                          backgroundColor: entry.correct == true
                              ? _micOn
                              : null,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Falsch erkannt',
                        onPressed: () => kitchen.markLogEntry(entry, false),
                        icon: const Icon(Icons.close_rounded),
                        color: entry.correct == false ? Colors.white : _ink,
                        style: IconButton.styleFrom(
                          backgroundColor: entry.correct == false
                              ? const Color(0xFFB0412E)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
