import 'package:mms_project/main.dart';

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
