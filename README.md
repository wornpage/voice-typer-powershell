# VoiceTyper

VoiceTyper is a small Windows PowerShell dictation app. It records your voice with a hotkey, transcribes the completed recording locally with `whisper.cpp`, then inserts the final text into the active app.

It was built for cases where real-time Whisper streaming is too delayed or unstable. Instead of typing partial text while you speak, VoiceTyper uses a push-to-talk flow:

1. Press `F8` or click `Record`.
2. Speak.
3. Press `F8` again or click `Stop`.
4. VoiceTyper transcribes the saved WAV file.
5. The transcript is pasted or typed into the target app.

The window is intentionally small, about 300 by 300 pixels, so it can sit beside Codex, Chrome, Notepad, or any other app.

## Features

- PowerShell-only app UI using WinForms.
- Local speech-to-text through `whisper.cpp` and `whisper-cli.exe`.
- Push-to-talk recording with `F8`.
- Optional manual `Record` and `Stop` buttons.
- Direct 16 kHz mono WAV recording through Windows `winmm.dll`.
- Active-window targeting, with optional locked target mode.
- Fast clipboard paste mode, with key-by-key typing fallback.
- Feedback sounds when recording starts and stops.
- Configurable model path, hotkey, output method, sounds, and target behavior.
- Transcript text stays in memory; WAV and per-run transcript logs are deleted after use by default.

## Files

- `VoiceTyper.ps1` - the main PowerShell app.
- `Install-VoiceTyperBackend.ps1` - setup helper for model and `whisper.cpp` binaries.
- `VoiceTyper.config.example.json` - sample config.
- `VoiceTyper.config.json` - local runtime config, created/updated on first run.
- `SPEC.md` - detailed implementation specification.

Generated folders:

- `models` - Whisper GGML model files.
- `vendor` - the pinned, SHA-256-verified `whisper.cpp` Windows release.
- `recordings` - transient push-to-talk WAV recordings.
- `logs` - bounded metadata/error logging and transient transcription files.

## Requirements

- Windows.
- PowerShell 7.
- A working microphone allowed by Windows privacy settings.
- `whisper-cli.exe` from `whisper.cpp`.
- A local GGML Whisper model, for example `ggml-base.en.bin`.

The setup helper downloads only the reviewed `whisper.cpp` release and model revisions embedded in the script. Every downloaded file must match its pinned SHA-256 digest before extraction or use.

## Setup

Run the setup helper:

```powershell
pwsh -NoProfile -File .\Install-VoiceTyperBackend.ps1
```

The helper:

- downloads the exact reviewed `whisper.cpp` Windows release;
- verifies the release SHA-256 before extracting it;
- downloads `ggml-base.en.bin` from an immutable model revision;
- verifies the model SHA-256 before use;
- writes only the verified paths into `VoiceTyper.config.json`.

Validate the pinned-source and privacy contract without downloading anything:

```powershell
pwsh -NoProfile -File .\tests\security-contract.ps1
```

## Run

```powershell
pwsh -NoProfile -File .\VoiceTyper.ps1
```

## Basic Workflow

1. Start VoiceTyper.
2. Click into the target text field, such as a Codex prompt, Chrome URL bar, Notepad, or an editor.
3. Press `F8` or click `Record`.
4. Speak.
5. Press `F8` again or click `Stop`.
6. Wait for transcription.
7. The final text is inserted into the target app.

The `Paste` checkbox controls output speed:

- checked: insert the transcript through the clipboard in one operation;
- unchecked: type through `SendKeys` character by character.

The `Lock` button is optional. Use it when you want VoiceTyper to keep sending output to one specific window instead of following the active foreground window.

## Config

Important config values in `VoiceTyper.config.json`:

- `WhisperCliPath`: path to `whisper-cli.exe`.
- `ModelPath`: path to the GGML Whisper model.
- `Language`: spoken language, default `en`.
- `Threads`: CPU threads used by Whisper.
- `Hotkey`: default `F8`.
- `AutoTypeAfterTranscribe`: insert final transcript automatically.
- `OutputMethod`: `Paste` or `Type`.
- `EnableFeedbackSounds`: play sounds on record start/stop.
- `RecordStartSound`: default `Asterisk`.
- `RecordStopSound`: default `Exclamation`.
- `TargetMode`: `ActiveWindow`, `Codex`, or `Locked`.
- `PreferredTargetTitle`: default `Codex`.
- `RefocusTargetBeforeTyping`: whether to force focus back to the target before output.
- `PreserveDebugArtifacts`: keep WAV and per-run stdout/stderr files after transcription; default `false`.

Legacy streaming settings such as `WhisperStreamPath`, `StepMs`, `LengthMs`, `KeepMs`, `MaxTokens`, and `AudioContext` are still present because earlier versions used `whisper-stream.exe`. The current default flow uses push-to-talk recording plus `whisper-cli.exe`.

## Diagnostics

VoiceTyper writes a bounded metadata/error log under `.\logs` without transcript text. By default, it removes each recording and the corresponding Whisper stdout/stderr files after transcription.

- `VoiceTyper.log` - app lifecycle, target selection, recording, transcription, output, and exceptions.
- `transcribe-*.stdout.log` - transient `whisper-cli.exe` output.
- `transcribe-*.stderr.log` - transient Whisper diagnostics.

Set `PreserveDebugArtifacts` to `true` only for a bounded debugging session. Existing artifacts from older versions are not deleted automatically; remove `.\recordings\*` and `.\logs\transcribe-*` after reviewing them.

## Known Limits

- This is not true real-time dictation. It transcribes after you stop recording.
- Clipboard paste mode temporarily replaces the clipboard, sends `Ctrl+V`, then tries to restore the previous clipboard text.
- Global hotkey handling is polling-based with `GetAsyncKeyState`, not a registered Windows hotkey.
- The app targets normal desktop text fields. Some elevated/admin apps may not accept pasted or typed input from a non-elevated PowerShell process.
- Accuracy and speed depend on the Whisper model and CPU.

## Why Push-To-Talk Instead Of Streaming?

The first implementation used `whisper-stream.exe` to emit partial text while speaking. On this Windows setup, the stream output behaved more like delayed chunks than reliable real-time dictation. It also revised partial text, which made target insertion harder.

The current design records first, transcribes once, and inserts the final result. This is slower than ideal live dictation, but more predictable and easier to share.
