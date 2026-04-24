# VoiceTyper Specification

## Purpose

VoiceTyper is a compact Windows PowerShell app for local push-to-talk dictation. It records microphone audio, transcribes the completed recording with a local Whisper model through `whisper.cpp`, and inserts the resulting text into another app.

The primary target workflow is voice input into apps that do not have built-in dictation, including Codex, browser text fields, editors, terminals, and notes apps.

## Design Goals

- Keep the app portable and script-based.
- Keep the UI small enough to float beside another app.
- Avoid cloud speech APIs.
- Use local `whisper.cpp` binaries and GGML models.
- Avoid unreliable partial streaming behavior.
- Make insertion fast by default through clipboard paste.
- Keep key-by-key typing available as a compatibility fallback.
- Provide visible and audible state feedback.
- Preserve logs and recordings for debugging.

## Non-Goals

- Full real-time word-by-word dictation.
- A packaged installer.
- Cross-platform support.
- Whisper model management beyond a basic setup helper.
- Advanced audio device selection UI.
- Guaranteed compatibility with elevated/admin target windows.

## Runtime Components

### `VoiceTyper.ps1`

Main PowerShell WinForms application.

Responsibilities:

- load config;
- create the 300x300 UI;
- track active/locked target windows;
- poll the hotkey;
- record WAV audio;
- run `whisper-cli.exe`;
- parse final transcript text;
- paste or type the transcript;
- play feedback sounds;
- write diagnostics.

### `Install-VoiceTyperBackend.ps1`

Setup helper.

Responsibilities:

- create `models` and `vendor` folders;
- download a GGML Whisper model;
- find existing `whisper-stream.exe` and `whisper-cli.exe`;
- download SDL2 development files;
- clone/build `whisper.cpp` when needed;
- write backend paths to `VoiceTyper.config.json`.

### `VoiceTyper.config.json`

Local runtime config. It is intentionally editable by hand through the `Config` button.

### `PcmWaveRecorder`

Embedded C# class compiled by PowerShell with `Add-Type`.

Responsibilities:

- open the default Windows microphone through `winmm.dll`;
- record PCM audio;
- write 16 kHz, mono, 16-bit WAV files;
- avoid the older MCI recorder path, which failed during testing.

## User Flow

### Normal Flow

1. User starts `VoiceTyper.ps1`.
2. App loads `VoiceTyper.config.json`.
3. User focuses the target app/text field.
4. User presses `F8` or clicks `Record`.
5. App plays the start sound.
6. App records microphone audio to memory.
7. User presses `F8` again or clicks `Stop`.
8. App writes a WAV file under `recordings`.
9. App plays the stop sound.
10. App runs `whisper-cli.exe` against the WAV file.
11. App reads final transcript output from `logs\transcribe-*.stdout.log`.
12. App cleans transcript text.
13. App inserts the final text into the target app.
14. App returns to ready state.

### Optional Locked Target Flow

1. User clicks `Lock`.
2. App gives a short countdown and minimizes.
3. User clicks the desired target window/text field.
4. App stores that window handle.
5. Future output goes to that locked target until unlocked.

## State Machine

```text
Ready
  -> Record button or F8
Recording
  -> Stop button or F8
Transcribing
  -> whisper-cli exits
Output
  -> paste/type complete
Ready
```

Failure states:

- missing backend binary;
- missing model file;
- microphone open failure;
- WAV save failure;
- transcription process failure;
- no transcript text;
- target window unavailable;
- clipboard failure.

Failures are logged to `logs\VoiceTyper.log`.

## Audio Recording

Recording is performed by the embedded `PcmWaveRecorder` C# class.

Format:

- WAV container;
- PCM;
- 16,000 Hz;
- mono;
- 16-bit samples.

Output path:

```text
recordings\voice-yyyyMMdd-HHmmss.wav
```

The recorder uses `waveInOpen`, `waveInPrepareHeader`, `waveInAddBuffer`, `waveInStart`, `waveInStop`, and `waveInClose` from `winmm.dll`.

## Transcription

VoiceTyper uses `whisper-cli.exe`, not `whisper-stream.exe`, for the current default flow.

Command shape:

```powershell
whisper-cli.exe -m "<ModelPath>" -f "<AudioPath>" -t <Threads> -l <Language> --no-timestamps
```

Stdout and stderr are redirected:

```text
logs\transcribe-yyyyMMdd-HHmmss.stdout.log
logs\transcribe-yyyyMMdd-HHmmss.stderr.log
```

The app reads stdout after the process exits and removes diagnostic/timestamp-like lines.

## Text Insertion

VoiceTyper supports two output modes.

### Paste Mode

Config:

```json
"OutputMethod": "Paste"
```

Flow:

1. Store current clipboard text if available.
2. Put transcript text on clipboard.
3. Send `Ctrl+V` to target app.
4. Restore previous clipboard text or clear the clipboard.

This is the default because it is much faster than key-by-key typing.

### Type Mode

Config:

```json
"OutputMethod": "Type"
```

Flow:

1. Escape transcript text for `SendKeys`.
2. Send text character by character.

This is slower but can work in fields where paste is blocked.

## Target Selection

Default:

```json
"TargetMode": "ActiveWindow"
```

Behavior:

- follow the active foreground window;
- avoid selecting the VoiceTyper window itself;
- optionally use `PreferredTargetTitle` as a fallback;
- support manual locked target mode through the `Lock` button.

Known limitation: Windows integrity levels apply. A non-admin VoiceTyper process may not insert text into an elevated/admin target.

## Hotkey Handling

Default:

```json
"Hotkey": "F8"
```

Implementation:

- polling timer;
- `GetAsyncKeyState`;
- edge detection so one key press toggles once.

Supported values:

- `F1` through `F12`;
- `Space`;
- unknown values fall back to `F8`.

This is simpler than registering a global hotkey and avoids extra message-loop plumbing, but polling can miss extremely brief key presses.

## Feedback Sounds

Config:

```json
"EnableFeedbackSounds": true,
"RecordStartSound": "Asterisk",
"RecordStopSound": "Exclamation"
```

Supported sound names:

- `Asterisk`;
- `Exclamation`;
- `Beep`;
- `Hand`;
- `Question`.

Implementation uses `.NET` `System.Media.SystemSounds`.

## Configuration Reference

| Key | Default | Description |
| --- | --- | --- |
| `WhisperCliPath` | local build path | Path to `whisper-cli.exe`. |
| `WhisperStreamPath` | legacy local build path | Path to `whisper-stream.exe`; retained for older experiments. |
| `ModelPath` | `.\models\ggml-base.en.bin` | GGML Whisper model path. |
| `Language` | `en` | Spoken language passed to Whisper. |
| `Threads` | `8` | CPU thread count for transcription. |
| `Mode` | `PushToTalk` | Current supported workflow. |
| `Hotkey` | `F8` | Toggle record/stop. |
| `AutoTypeAfterTranscribe` | `true` | Insert transcript automatically. |
| `OutputMethod` | `Paste` | `Paste` or `Type`. |
| `EnableFeedbackSounds` | `true` | Play start/stop sounds. |
| `RecordStartSound` | `Asterisk` | Sound when recording starts. |
| `RecordStopSound` | `Exclamation` | Sound when recording stops. |
| `TargetMode` | `ActiveWindow` | `ActiveWindow`, `Codex`, or `Locked`. |
| `PreferredTargetTitle` | `Codex` | Fallback target title pattern. |
| `RefocusTargetBeforeTyping` | `false` | Force focus before output when needed. |
| `StartDelaySeconds` | `2` | Delay used by manual target lock. |

Legacy streaming keys retained in config:

- `StepMs`;
- `LengthMs`;
- `KeepMs`;
- `MaxTokens`;
- `AudioContext`;
- `UseVadMode`;
- `VadThreshold`;
- `ExtraArgs`;
- `TypingMode`;
- `TypeSeparator`.

## Diagnostics

Logs:

```text
logs\VoiceTyper.log
logs\transcribe-*.stdout.log
logs\transcribe-*.stderr.log
```

Recordings:

```text
recordings\voice-*.wav
```

Useful debugging checks:

```powershell
.\vendor\whisper.cpp-build\bin\Release\whisper-cli.exe --help
Get-Content .\logs\VoiceTyper.log -Tail 80
Get-ChildItem .\recordings
```

## Security And Privacy

- Audio recordings stay on the local machine.
- Transcription uses a local model.
- No OpenAI API key is required.
- No cloud API call is made by the main app.
- The setup helper downloads dependencies/model files from public sources.
- Clipboard paste mode temporarily modifies the clipboard, then attempts to restore it.

## Known Limitations

- Not true real-time streaming.
- Uses the default microphone; no in-app microphone picker yet.
- Global hotkey is polling-based.
- Clipboard restore only handles text clipboard content.
- Some apps block paste or simulated input.
- Some elevated windows require VoiceTyper to also run elevated.
- Large models improve accuracy but increase transcription delay.

## Future Improvements

- Microphone device selector.
- Registered global hotkey instead of polling.
- Optional auto-stop after silence.
- Model selector and benchmark view.
- Tray mode.
- Better clipboard preservation for non-text formats.
- Optional cleanup of old recordings/logs.
- Revisit streaming mode if a more reliable local backend is used.
