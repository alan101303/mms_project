import 'package:mms_project/evaluation_log.dart';
import 'package:mms_project/main.dart';
import 'package:permission_handler/permission_handler.dart';

/// Records sounds instead of playing them, since tests have no audio plugin.
class FakeSoundEffects extends SoundEffects {
  final played = <UiSound>[];
  bool alarmPlaying = false;

  @override
  Future<void> play(UiSound sound) async => played.add(sound);

  @override
  Future<void> startAlarm() async => alarmPlaying = true;

  @override
  Future<void> stopAlarm() async => alarmPlaying = false;

  @override
  void dispose() {}
}

/// A mic permission whose answers the test decides.
class FakeMicPermission extends MicPermission {
  FakeMicPermission(this.current, {this.afterRequest = PermissionStatus.granted});

  PermissionStatus current;
  final PermissionStatus afterRequest;
  bool settingsOpened = false;

  @override
  Future<PermissionStatus> status() async => current;

  @override
  Future<PermissionStatus> request() async => current = afterRequest;

  @override
  Future<bool> openSettings() async => settingsOpened = true;
}

/// Keeps the evaluation log in memory.
class MemoryEvaluationStorage extends EvaluationStorage {
  List<VoiceLogEntry> saved = [];

  @override
  Future<List<VoiceLogEntry>> load() async => saved;

  @override
  Future<void> save(List<VoiceLogEntry> entries) async => saved = [...entries];
}
