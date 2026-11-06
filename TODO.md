# TODO

Gaps between [Proposal.pdf](Proposal.pdf) and the current code, from a code review on 2026-11-01.
The analyzer and the one widget test pass, but nothing here has been tried on a real phone yet.

Tags: **[verified]** = reproduced by running the code or checked against SDK/plugin sources.
**[device]** = needs checking or measuring on a phone. Untagged items come from reading the code.
Line numbers refer to the review date and will drift.

## 1. Must fix (blocks the proposal goals)

All items below are implemented (2026-11-06) and covered by `flutter test` where possible,
but **nothing has been tried on a phone yet**. Check the **[device]** notes first.

- [x] **Add `RecognitionService` to `<queries>`** in [AndroidManifest.xml](android/app/src/main/AndroidManifest.xml). **[device]** Confirm the mic works on an Android 11+ phone.
- [x] **Hands-free listening.** Tapping the mic turns on a Listening → Processing → Speaking → Listening loop (`VoiceState`). It runs until the mic is tapped again or the cooking page closes. The mic is closed while the app speaks.
  - Uses the TTS completion, cancel and error handlers instead of `awaitSpeakCompletion(true)`. On Android, a stopped utterance never completes an awaited `speak()`, which would freeze the loop.
  - **[device]** Android's recognizer plays its own start beep on every restart (about every 5–20 s in silence).
  - **[device]** Every utterance is treated as a command, so nearby conversation triggers „nicht verstanden" replies.
  - **[device]** Check battery use and whether the beeps are acceptable during a full recipe.
- [x] **Real timer alarm.** Bundled `assets/sounds/alarm.wav` loops on the alarm audio stream. It stops via „Alarm aus" on the timer card, any voice command, or automatically after 2 minutes. The timer card is now also shown on the home screen.
- [x] **Reliable confirmation sounds.** Bundled sounds (`audioplayers`):
  - `heard`: first recognized word
  - `success`: command understood
  - `question`: follow-up question
  - `error`: not understood or recognition failed
  - **[device]** Check volume, and whether the recognizer mutes them while listening.
- [x] **Real follow-up question.**
  - „Meintest du „X"?" names the command that was actually heard, including the minutes for timers.
  - It's triggered by low confidence or by a near miss (edit distance, e.g. „leiter" → „Weiter").
  - Answer by voice („ja"/„nein") or with the Ja/Nein buttons in the dock.
- [x] **Make feedback visible.** The dock and the home voice card now show the recognized text, the feedback (up to 3 lines) and the mic status. Permission and recognition errors are mapped to German messages.
- [x] **Fix mic colours.** Green while listening, grey otherwise. A speaker icon shows while the app talks, with a status line below the mic.
- [x] **Keep the screen on** while the cooking page is open (`wakelock_plus`).

## 2. Bugs

### Timer parsing

`_parseMinutes` ([main.dart:459](lib/main.dart#L459)) matches substrings. Replace it with proper German number parsing, including hours and seconds. **[verified]**

| Spoken command | Current result |
| --- | --- |
| „Timer fünfzehn Minuten" | 5 min |
| „Timer dreißig Minuten" | 3 min |
| „Timer vierzig Minuten" | 4 min |
| „Timer fünfundzwanzig Minuten" | 5 min |
| „Stelle einen Timer auf fünf Minuten" | 1 min |
| „Timer einstellen" | starts a 1-minute timer |
| „Timer eine Stunde" | 1 min |
| „Timer 30 Sekunden" | 30 min |
| „Timer stoppen" | asks how many minutes |

### Pause and undo

- [ ] „Pause" doesn't stop the timer, although the help sketch says it should. **[verified]**
- [ ] Undo is active right after opening a recipe: after opening recipe 3, it jumped to recipe 1 and left it unpaused ([main.dart:264](lib/main.dart#L264)). **[verified]**
- [ ] Undo rewinds a running timer (50 s back to 200 s in testing). **[verified]**
- [ ] Undo restores the paused state but still reads the step aloud ([main.dart:235](lib/main.dart#L235)).

### Command matching

- [ ] Add missing synonyms: „nächster Schritt", „nächste", „was kommt danach". **[verified]**
- [ ] Add voice commands „Hilfe" and „Rückgängig". **[verified]**
- [ ] Match partial recipe names such as „Tomatenpasta" and „Pfannkuchen" ([main.dart:450](lib/main.dart#L450)). **[verified]**
- [ ] Match whole words, not substrings: „nicht weiter" currently moves to the next step. **[verified]**

### Speech and flow

- [ ] Stop text-to-speech when the mic is tapped, so the app can't hear itself.
- [ ] Stop reading when leaving the cooking page.
- [ ] Replace raw error codes such as `error_no_match` ([main.dart:154](lib/main.dart#L154)) with the help text.
- [ ] After choosing a recipe by voice, respond by voice. „Tippe auf Start" ([main.dart:269](lib/main.dart#L269)) asks for touch in a hands-free flow.
- [ ] Don't silently reset progress when reopening a recipe.
- [ ] Show a running timer on the home screen.

## 3. Missing from the proposal

- [ ] **Screen 1, Berechtigung:** explanation and Freigabe button, plus an `openAppSettings` link if permission is permanently denied.
- [ ] **Timer controls:** pause and cancel, by both touch and voice (goal 3).
- [ ] **Button highlight:** buttons turn green when activated by touch or voice, as in the sketch. Remove the unused `selectedInput` and `setInputMode` ([main.dart:102](lib/main.dart#L102)).
- [ ] **Help:** reachable from the cooking page, and with the mic status section from the sketch.
- [ ] **Ingredients:** make the card closable, or turn it into the separate screen 4 from the proposal.
- [ ] **Evaluation logging (AP8):** record the recognized text, matched command, confidence and timestamps. Needed to report recognition rate and prove the 1-second goal. Have this ready before evaluation starts on 24.11.

## 4. Could be improved

- [ ] **Readability:** step text is 20 pt and buttons use 21 px icons with no labels ([main.dart:1100](lib/main.dart#L1100)). The sketch shows large Weiter and Zurück buttons.
- [ ] **Contrast:** `#888C83` is 3.14:1, and `#71766F` and `#777D74` are about 4.2:1, all below the 4.5:1 WCAG AA target for small text. Also raise the 11–12 pt text sizes.
- [ ] **Button position:** the controls scroll with the content ([main.dart:1022](lib/main.dart#L1022)), so the ingredients card and timer can push them off screen. Pin them at the bottom.
- [ ] **Latency:** with `pauseFor` at 3 s, commands may run well after the user stops speaking. Measure, then shorten it or act on partial results for one-word commands. **[device]**
- [ ] **Code structure:** split up the 1,310-line `main.dart`, move the parser into a pure class, and inject the speech services.
- [ ] **Tests:** add unit tests for the parser, undo and timer. The current test covers almost no voice logic.
- [ ] **Timer accuracy:** use an end timestamp, since the in-app countdown may drift or stop in the background. **[device]**
- [ ] **Dependencies:** `flutter_tts` triggers a Gradle warning that future Flutter versions will fail the build. Check for an updated version.
- [ ] **Proposal dates:** the chart has AP1 starting 09.10 but the text says 12.10, and AP9 runs to 07.12, after the 01.12 presentation.

## Suggested order

1. Fix the manifest and test recognition on a phone.
2. Replace the parser and add its unit tests.
3. Build the listening loop.
4. Add sounds, visible feedback and mic colours.
5. Build the permission screen and timer controls.
6. Add evaluation logging before 24.11.
