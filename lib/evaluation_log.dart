import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// What the app did with one voice input.
enum VoiceOutcome {
  command('Befehl'),
  recipe('Rezept'),
  question('Rückfrage'),
  answer('Antwort'),
  notUnderstood('Nicht verstanden');

  const VoiceOutcome(this.label);

  final String label;
}

/// One voice input, recorded for the evaluation (AP8).
class VoiceLogEntry {
  VoiceLogEntry({
    required this.time,
    required this.text,
    required this.confidence,
    required this.outcome,
    required this.detail,
    this.feedbackMs,
    this.correct,
  });

  factory VoiceLogEntry.fromJson(Map<String, dynamic> json) => VoiceLogEntry(
    time: DateTime.parse(json['time'] as String),
    text: json['text'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    outcome: VoiceOutcome.values.byName(json['outcome'] as String),
    detail: json['detail'] as String,
    feedbackMs: json['feedbackMs'] as int?,
    correct: json['correct'] as bool?,
  );

  /// When the first words were recognized.
  final DateTime time;
  final String text;

  /// Between 0 and 1; negative when the recognizer gave no score.
  final double confidence;
  final VoiceOutcome outcome;

  /// The command, recipe or question the input led to.
  final String detail;

  /// Time from the last change of the recognized words (roughly the end of
  /// speech) to the confirmation sound and on-screen feedback.
  final int? feedbackMs;

  /// Whether the evaluator marked the recognition as right; null if unmarked.
  bool? correct;

  Map<String, Object?> toJson() => {
    'time': time.toIso8601String(),
    'text': text,
    'confidence': confidence,
    'outcome': outcome.name,
    'detail': detail,
    'feedbackMs': feedbackMs,
    'correct': correct,
  };
}

/// Figures for the evaluation page and the presentation.
class VoiceLogSummary {
  factory VoiceLogSummary.of(List<VoiceLogEntry> entries) {
    int count(bool Function(VoiceLogEntry entry) test) =>
        entries.where(test).length;
    final times = [
      for (final entry in entries)
        if (entry.feedbackMs != null) entry.feedbackMs!,
    ]..sort();
    return VoiceLogSummary._(
      total: entries.length,
      executed: count(
        (entry) =>
            entry.outcome == VoiceOutcome.command ||
            entry.outcome == VoiceOutcome.recipe ||
            entry.outcome == VoiceOutcome.answer,
      ),
      questions: count((entry) => entry.outcome == VoiceOutcome.question),
      notUnderstood: count(
        (entry) => entry.outcome == VoiceOutcome.notUnderstood,
      ),
      marked: count((entry) => entry.correct != null),
      markedCorrect: count((entry) => entry.correct ?? false),
      timed: times.length,
      underOneSecond: times.where((ms) => ms < 1000).length,
      medianMs: times.isEmpty ? null : times[times.length ~/ 2],
      maxMs: times.isEmpty ? null : times.last,
    );
  }

  const VoiceLogSummary._({
    required this.total,
    required this.executed,
    required this.questions,
    required this.notUnderstood,
    required this.marked,
    required this.markedCorrect,
    required this.timed,
    required this.underOneSecond,
    required this.medianMs,
    required this.maxMs,
  });

  final int total;
  final int executed;
  final int questions;
  final int notUnderstood;
  final int marked;
  final int markedCorrect;
  final int timed;
  final int underOneSecond;
  final int? medianMs;
  final int? maxMs;
}

/// Stores the log as JSON lines in the app's files. On Android this is
/// `Android/data/com.example.mms_project/files/`, reachable over USB.
class EvaluationStorage {
  static const _logName = 'voice_log.jsonl';
  static const _csvName = 'voice_log.csv';

  Future<List<VoiceLogEntry>> load() async {
    try {
      final file = File('${(await _directory()).path}/$_logName');
      if (!await file.exists()) return [];
      return [
        for (final line in await file.readAsLines())
          if (line.trim().isNotEmpty)
            VoiceLogEntry.fromJson(jsonDecode(line) as Map<String, dynamic>),
      ];
    } catch (_) {
      // A missing or broken log starts a fresh one.
      return [];
    }
  }

  Future<void> save(List<VoiceLogEntry> entries) async {
    try {
      final file = File('${(await _directory()).path}/$_logName');
      await file.writeAsString(
        entries.map((entry) => jsonEncode(entry.toJson())).join('\n'),
      );
    } catch (_) {
      // Logging must never break the app.
    }
  }

  /// Writes a semicolon-separated file for Excel and returns its path.
  Future<String?> exportCsv(List<VoiceLogEntry> entries) async {
    String cell(Object? value) =>
        '"${(value ?? '').toString().replaceAll('"', '""')}"';
    final rows = [
      'Zeit;Erkannter Text;Konfidenz;Ergebnis;Detail;Rückmeldung (ms);Korrekt',
      for (final entry in entries)
        [
          cell(entry.time.toIso8601String()),
          cell(entry.text),
          cell(
            entry.confidence < 0
                ? ''
                : entry.confidence.toStringAsFixed(2).replaceAll('.', ','),
          ),
          cell(entry.outcome.label),
          cell(entry.detail),
          cell(entry.feedbackMs),
          cell(switch (entry.correct) {
            true => 'ja',
            false => 'nein',
            null => '',
          }),
        ].join(';'),
    ];
    try {
      final file = File('${(await _directory()).path}/$_csvName');
      // The byte order mark makes Excel read the umlauts correctly.
      await file.writeAsString('﻿${rows.join('\r\n')}');
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _directory() async {
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    } catch (_) {
      // Only Android has app-specific external storage.
    }
    return getApplicationDocumentsDirectory();
  }
}
