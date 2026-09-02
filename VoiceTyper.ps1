param(
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("NativeWindowTools" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeWindowTools {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    public static extern int mciSendString(string command, StringBuilder returnValue, int returnLength, IntPtr winHandle);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
}

if (-not ("PcmWaveRecorder" -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public class PcmWaveRecorder {
    private const int CALLBACK_FUNCTION = 0x00030000;
    private const int WAVE_FORMAT_PCM = 1;
    private const int WIM_DATA = 0x3C0;
    private const int BufferSize = 8192;
    private const int BufferCount = 4;

    [StructLayout(LayoutKind.Sequential)]
    private struct WaveFormatEx {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    private delegate void WaveInProc(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

    [DllImport("winmm.dll")]
    private static extern int waveInOpen(out IntPtr hWaveIn, int uDeviceID, ref WaveFormatEx lpFormat, WaveInProc dwCallback, IntPtr dwInstance, int dwFlags);

    [DllImport("winmm.dll")]
    private static extern int waveInPrepareHeader(IntPtr hWaveIn, IntPtr lpWaveInHdr, uint uSize);

    [DllImport("winmm.dll")]
    private static extern int waveInUnprepareHeader(IntPtr hWaveIn, IntPtr lpWaveInHdr, uint uSize);

    [DllImport("winmm.dll")]
    private static extern int waveInAddBuffer(IntPtr hWaveIn, IntPtr lpWaveInHdr, uint uSize);

    [DllImport("winmm.dll")]
    private static extern int waveInStart(IntPtr hWaveIn);

    [DllImport("winmm.dll")]
    private static extern int waveInStop(IntPtr hWaveIn);

    [DllImport("winmm.dll")]
    private static extern int waveInReset(IntPtr hWaveIn);

    [DllImport("winmm.dll")]
    private static extern int waveInClose(IntPtr hWaveIn);

    private readonly object sync = new object();
    private readonly List<GCHandle> pinned = new List<GCHandle>();
    private readonly List<IntPtr> headers = new List<IntPtr>();
    private MemoryStream audio = new MemoryStream();
    private WaveInProc callback;
    private IntPtr handle = IntPtr.Zero;
    private string outputPath = "";
    private bool recording = false;

    public void Start(string path) {
        if (recording) {
            return;
        }

        outputPath = path;
        audio = new MemoryStream();

        WaveFormatEx format = new WaveFormatEx();
        format.wFormatTag = WAVE_FORMAT_PCM;
        format.nChannels = 1;
        format.nSamplesPerSec = 16000;
        format.wBitsPerSample = 16;
        format.nBlockAlign = (ushort)(format.nChannels * format.wBitsPerSample / 8);
        format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
        format.cbSize = 0;

        callback = OnWaveIn;
        int result = waveInOpen(out handle, -1, ref format, callback, IntPtr.Zero, CALLBACK_FUNCTION);
        if (result != 0) {
            throw new InvalidOperationException("waveInOpen failed: " + result);
        }

        uint headerSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
        for (int i = 0; i < BufferCount; i++) {
            byte[] buffer = new byte[BufferSize];
            GCHandle bufferHandle = GCHandle.Alloc(buffer, GCHandleType.Pinned);
            pinned.Add(bufferHandle);

            WaveHeader header = new WaveHeader();
            header.lpData = bufferHandle.AddrOfPinnedObject();
            header.dwBufferLength = BufferSize;

            IntPtr headerPtr = Marshal.AllocHGlobal((int)headerSize);
            Marshal.StructureToPtr(header, headerPtr, false);
            headers.Add(headerPtr);

            result = waveInPrepareHeader(handle, headerPtr, headerSize);
            if (result != 0) {
                throw new InvalidOperationException("waveInPrepareHeader failed: " + result);
            }
            result = waveInAddBuffer(handle, headerPtr, headerSize);
            if (result != 0) {
                throw new InvalidOperationException("waveInAddBuffer failed: " + result);
            }
        }

        recording = true;
        result = waveInStart(handle);
        if (result != 0) {
            throw new InvalidOperationException("waveInStart failed: " + result);
        }
    }

    public string Stop() {
        if (!recording) {
            return outputPath;
        }

        recording = false;
        waveInStop(handle);
        waveInReset(handle);

        uint headerSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
        foreach (IntPtr header in headers) {
            waveInUnprepareHeader(handle, header, headerSize);
            Marshal.FreeHGlobal(header);
        }
        headers.Clear();

        foreach (GCHandle item in pinned) {
            if (item.IsAllocated) {
                item.Free();
            }
        }
        pinned.Clear();

        waveInClose(handle);
        handle = IntPtr.Zero;

        WriteWaveFile(outputPath, audio.ToArray());
        return outputPath;
    }

    private void OnWaveIn(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2) {
        if (uMsg != WIM_DATA || dwParam1 == IntPtr.Zero) {
            return;
        }

        WaveHeader header = (WaveHeader)Marshal.PtrToStructure(dwParam1, typeof(WaveHeader));
        if (header.dwBytesRecorded > 0) {
            byte[] data = new byte[header.dwBytesRecorded];
            Marshal.Copy(header.lpData, data, 0, data.Length);
            lock (sync) {
                audio.Write(data, 0, data.Length);
            }
        }

        if (recording) {
            header.dwBytesRecorded = 0;
            Marshal.StructureToPtr(header, dwParam1, false);
            waveInAddBuffer(hwi, dwParam1, (uint)Marshal.SizeOf(typeof(WaveHeader)));
        }
    }

    private static void WriteWaveFile(string path, byte[] pcmData) {
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write)) {
            using (BinaryWriter writer = new BinaryWriter(fs)) {
                writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
                writer.Write(36 + pcmData.Length);
                writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
                writer.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
                writer.Write(16);
                writer.Write((short)1);
                writer.Write((short)1);
                writer.Write(16000);
                writer.Write(16000 * 2);
                writer.Write((short)2);
                writer.Write((short)16);
                writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
                writer.Write(pcmData.Length);
                writer.Write(pcmData);
            }
        }
    }
}
"@
}

$script:AppRoot = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $script:AppRoot "VoiceTyper.config.json"
}

$script:Config = $null
$script:TargetHandle = [IntPtr]::Zero
$script:TargetTitle = ""
$script:WhisperProcess = $null
$script:LastTranscript = ""
$script:LastTypedAt = Get-Date
$script:IsTypingEnabled = $true
$script:OutputHandlers = @()
$script:CurrentProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
$script:IsTargetLocked = $false
$script:LogRoot = Join-Path $script:AppRoot "logs"
$script:AppLogPath = Join-Path $script:LogRoot "VoiceTyper.log"
$script:WhisperStdoutPath = ""
$script:WhisperStderrPath = ""
$script:WhisperStdoutOffset = [int64]0
$script:WhisperStderrOffset = [int64]0
$script:LastTargetKey = ""
$script:IsRecording = $false
$script:IsTranscribing = $false
$script:CurrentRecordingPath = ""
$script:RecordingsRoot = Join-Path $script:AppRoot "recordings"
$script:TranscribeProcess = $null
$script:TranscribeOutputPath = ""
$script:TranscribeErrorPath = ""
$script:HotkeyWasDown = $false
$script:Recorder = New-Object PcmWaveRecorder
New-Item -ItemType Directory -Force -Path $script:LogRoot | Out-Null
New-Item -ItemType Directory -Force -Path $script:RecordingsRoot | Out-Null

function Write-Log {
    param([string]$Message)
    if ((Test-Path -LiteralPath $script:AppLogPath -PathType Leaf) -and
        (Get-Item -LiteralPath $script:AppLogPath).Length -gt 1MB) {
        Clear-Content -LiteralPath $script:AppLogPath
    }
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Add-Content -LiteralPath $script:AppLogPath -Value $line -Encoding UTF8
}

function Remove-PrivateArtifacts {
    $preserve = [bool](Get-ConfigValue -Config $script:Config -Name "PreserveDebugArtifacts" -Default $false)
    if ($preserve) {
        return
    }

    foreach ($path in @(
        $script:CurrentRecordingPath,
        $script:TranscribeOutputPath,
        $script:TranscribeErrorPath
    )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    $script:CurrentRecordingPath = ""
    $script:TranscribeOutputPath = ""
    $script:TranscribeErrorPath = ""
}

Write-Log "VoiceTyper starting"

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $eventArgs)
    Write-Log "WinForms thread exception: $($eventArgs.Exception)"
    [System.Windows.Forms.MessageBox]::Show($eventArgs.Exception.Message, "Voice Typer Error") | Out-Null
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $eventArgs)
    Write-Log "Unhandled exception: $($eventArgs.ExceptionObject)"
})

function New-DefaultConfig {
    [ordered]@{
        WhisperStreamPath = ".\vendor\whisper-b4938\Release\whisper-stream.exe"
        WhisperCliPath = ".\vendor\whisper-b4938\Release\whisper-cli.exe"
        ModelPath = ".\models\ggml-base.en.bin"
        Language = "en"
        Threads = 8
        StepMs = 250
        LengthMs = 2500
        KeepMs = 100
        MaxTokens = 24
        AudioContext = 512
        UseVadMode = $false
        VadThreshold = 0.6
        ExtraArgs = ""
        TypingMode = "Delta"
        TypeSeparator = " "
        RefocusTargetBeforeTyping = $false
        StartDelaySeconds = 2
        TargetMode = "ActiveWindow"
        PreferredTargetTitle = "Codex"
        Mode = "PushToTalk"
        Hotkey = "F8"
        AutoTypeAfterTranscribe = $true
        OutputMethod = "Paste"
        EnableFeedbackSounds = $true
        RecordStartSound = "Asterisk"
        RecordStopSound = "Exclamation"
        PreserveDebugArtifacts = $false
    }
}

function Save-Config {
    param([object]$Config)
    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Save-Config -Config (New-DefaultConfig)
    }

    $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $defaults = New-DefaultConfig
    foreach ($key in $defaults.Keys) {
        if (-not ($loaded.PSObject.Properties.Name -contains $key)) {
            $loaded | Add-Member -MemberType NoteProperty -Name $key -Value $defaults[$key]
        }
    }
    return $loaded
}

function Resolve-AppPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }
    return (Join-Path $script:AppRoot $expanded)
}

function Get-ConfigValue {
    param(
        [object]$Config,
        [string]$Name,
        [object]$Default
    )
    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Name) {
        return $Config.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Quote-Arg {
    param([string]$Value)
    if ($null -eq $Value) {
        return '""'
    }
    '"' + ($Value -replace '"', '\"') + '"'
}

function Get-WindowTitle {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) {
        return ""
    }
    $builder = New-Object System.Text.StringBuilder 512
    [void][NativeWindowTools]::GetWindowText($Handle, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Get-WindowProcessId {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) {
        return 0
    }
    $windowProcessId = [uint32]0
    [void][NativeWindowTools]::GetWindowThreadProcessId($Handle, [ref]$windowProcessId)
    return [int]$windowProcessId
}

function Set-TargetFromForegroundWindow {
    $handle = [NativeWindowTools]::GetForegroundWindow()
    if (-not (Test-UsableTargetWindow $handle)) {
        return $false
    }

    Set-TargetWindow -Handle $handle
    return $true
}

function Test-UsableTargetWindow {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) {
        return $false
    }
    if ((Get-WindowProcessId $Handle) -eq $script:CurrentProcessId) {
        return $false
    }
    return $true
}

function Set-TargetWindow {
    param([IntPtr]$Handle)
    $script:TargetHandle = $Handle
    $script:TargetTitle = Get-WindowTitle $script:TargetHandle
    if ([string]::IsNullOrWhiteSpace($script:TargetTitle)) {
        $script:TargetTitle = "Selected window"
    }
}

function Get-TargetKey {
    if ($script:TargetHandle -eq [IntPtr]::Zero) {
        return ""
    }
    return "{0}|{1}" -f $script:TargetHandle.ToInt64(), $script:TargetTitle
}

function Refresh-TargetForTranscript {
    $before = $script:LastTargetKey
    if (-not (Resolve-TypingTarget)) {
        return $false
    }

    $after = Get-TargetKey
    if (-not [string]::IsNullOrWhiteSpace($before) -and $after -ne $before) {
        $script:LastTranscript = ""
        Write-Log "Target changed; transcript delta reset. New target: $script:TargetTitle"
    }
    $script:LastTargetKey = $after
    return $true
}

function Find-WindowByTitle {
    param([string]$TitlePattern)
    if ([string]::IsNullOrWhiteSpace($TitlePattern)) {
        return [IntPtr]::Zero
    }

    $match = Get-Process |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -match $TitlePattern } |
        Select-Object -First 1

    if ($null -eq $match) {
        return [IntPtr]::Zero
    }
    return [IntPtr]$match.MainWindowHandle
}

function Resolve-TypingTarget {
    $mode = [string](Get-ConfigValue -Config $script:Config -Name "TargetMode" -Default "ActiveWindow")
    $preferredTitle = [string](Get-ConfigValue -Config $script:Config -Name "PreferredTargetTitle" -Default "Codex")

    if ($script:IsTargetLocked -or $mode.Equals("Locked", [StringComparison]::OrdinalIgnoreCase)) {
        return (Test-UsableTargetWindow $script:TargetHandle)
    }

    $foreground = [NativeWindowTools]::GetForegroundWindow()
    if (Test-UsableTargetWindow $foreground) {
        Set-TargetWindow -Handle $foreground
        return $true
    }

    if ($mode.Equals("Codex", [StringComparison]::OrdinalIgnoreCase) -or
        ($mode.Equals("ActiveWindow", [StringComparison]::OrdinalIgnoreCase) -and -not (Test-UsableTargetWindow $script:TargetHandle))) {
        $preferred = Find-WindowByTitle $preferredTitle
        if (Test-UsableTargetWindow $preferred) {
            Set-TargetWindow -Handle $preferred
            return $true
        }
    }

    return (Test-UsableTargetWindow $script:TargetHandle)
}

function Find-WhisperStreamPath {
    $configured = Resolve-AppPath $script:Config.WhisperStreamPath
    if (Test-Path -LiteralPath $configured -PathType Leaf) {
        return $configured
    }
    return ""
}

function Find-WhisperCliPath {
    $configured = Resolve-AppPath (Get-ConfigValue -Config $script:Config -Name "WhisperCliPath" -Default "")
    if (Test-Path -LiteralPath $configured -PathType Leaf) {
        return $configured
    }
    return ""
}

function Find-WhisperModelPath {
    $configured = Resolve-AppPath $script:Config.ModelPath
    if (Test-Path -LiteralPath $configured -PathType Leaf) {
        return $configured
    }
    return ""
}

function Update-DiscoveredBackendPaths {
    $changed = $false
    $whisperPath = Find-WhisperStreamPath
    if (-not [string]::IsNullOrWhiteSpace($whisperPath)) {
        $script:Config.WhisperStreamPath = $whisperPath
        $changed = $true
    }

    $cliPath = Find-WhisperCliPath
    if (-not [string]::IsNullOrWhiteSpace($cliPath)) {
        if ($script:Config.PSObject.Properties.Name -contains "WhisperCliPath") {
            $script:Config.WhisperCliPath = $cliPath
        }
        else {
            $script:Config | Add-Member -MemberType NoteProperty -Name "WhisperCliPath" -Value $cliPath
        }
        $changed = $true
    }

    $modelPath = Find-WhisperModelPath
    if (-not [string]::IsNullOrWhiteSpace($modelPath)) {
        $script:Config.ModelPath = $modelPath
        $changed = $true
    }

    if ($changed) {
        Save-Config -Config $script:Config
    }
}

function Read-NewLogLines {
    param(
        [string]$Path,
        [ref]$Offset
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Offset.Value -gt $stream.Length) {
            $Offset.Value = 0
        }
        [void]$stream.Seek([int64]$Offset.Value, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        if ([string]::IsNullOrEmpty($text)) {
            return @()
        }
        return ($text -split "\r\n|\n|\r") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    catch {
        Write-Log "Read-NewLogLines failed for $Path`: $($_.Exception.Message)"
        return @()
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Play-FeedbackSound {
    param([string]$State)

    try {
        $enabled = [bool](Get-ConfigValue -Config $script:Config -Name "EnableFeedbackSounds" -Default $true)
        if (-not $enabled) {
            return
        }

        $soundName = if ($State -eq "Start") {
            [string](Get-ConfigValue -Config $script:Config -Name "RecordStartSound" -Default "Asterisk")
        }
        else {
            [string](Get-ConfigValue -Config $script:Config -Name "RecordStopSound" -Default "Exclamation")
        }

        switch ($soundName.ToLowerInvariant()) {
            "beep" { [System.Media.SystemSounds]::Beep.Play(); break }
            "hand" { [System.Media.SystemSounds]::Hand.Play(); break }
            "question" { [System.Media.SystemSounds]::Question.Play(); break }
            "exclamation" { [System.Media.SystemSounds]::Exclamation.Play(); break }
            default { [System.Media.SystemSounds]::Asterisk.Play(); break }
        }
    }
    catch {
        Write-Log "Play-FeedbackSound failed: $($_.Exception.Message)"
    }
}

function Start-VoiceRecording {
    if ($script:IsRecording -or $script:IsTranscribing) {
        return
    }

    $script:CurrentRecordingPath = Join-Path $script:RecordingsRoot ("voice-{0}.wav" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    try {
        $script:Recorder.Start($script:CurrentRecordingPath)
        $script:IsRecording = $true
        $statusLabel.Text = "Recording"
        $startButton.Enabled = $false
        $stopButton.Enabled = $true
        Play-FeedbackSound "Start"
        Write-Log "Recording started: $script:CurrentRecordingPath"
    }
    catch {
        $script:IsRecording = $false
        Write-Log "Start-VoiceRecording failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Voice Typer") | Out-Null
    }
}

function Stop-VoiceRecording {
    if (-not $script:IsRecording) {
        return
    }

    try {
        $savedPath = $script:Recorder.Stop()
        $script:IsRecording = $false
        $statusLabel.Text = "Transcribing"
        Play-FeedbackSound "Stop"
        Write-Log "Recording saved: $savedPath"
        Start-Transcription -AudioPath $savedPath
    }
    catch {
        $script:IsRecording = $false
        Write-Log "Stop-VoiceRecording failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Voice Typer") | Out-Null
        $startButton.Enabled = $true
        $stopButton.Enabled = $false
    }
}

function Build-WhisperCliArguments {
    param([string]$AudioPath)

    $modelPath = Resolve-AppPath $script:Config.ModelPath
    $args = @(
        "-m", (Quote-Arg $modelPath),
        "-f", (Quote-Arg $AudioPath),
        "-t", [string]$script:Config.Threads,
        "-l", [string]$script:Config.Language,
        "--no-timestamps"
    )

    return ($args -join " ")
}

function Start-Transcription {
    param([string]$AudioPath)

    $cliPath = Resolve-AppPath (Get-ConfigValue -Config $script:Config -Name "WhisperCliPath" -Default "")
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        Offer-BackendSetup "Cannot find whisper-cli.exe.`r`n`r`nVoiceTyper needs whisper-cli.exe for push-to-talk transcription."
        $startButton.Enabled = $true
        $stopButton.Enabled = $false
        return
    }

    $runId = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:TranscribeOutputPath = Join-Path $script:LogRoot "transcribe-$runId.stdout.log"
    $script:TranscribeErrorPath = Join-Path $script:LogRoot "transcribe-$runId.stderr.log"
    New-Item -ItemType File -Force -Path $script:TranscribeOutputPath, $script:TranscribeErrorPath | Out-Null

    $arguments = Build-WhisperCliArguments -AudioPath $AudioPath
    Write-Log "Starting transcription with configured local backend."

    $script:IsTranscribing = $true
    $startButton.Enabled = $false
    $stopButton.Enabled = $false
    try {
        $script:TranscribeProcess = Start-Process -FilePath $cliPath `
            -ArgumentList $arguments `
            -WorkingDirectory (Split-Path -Parent $cliPath) `
            -WindowStyle Hidden `
            -RedirectStandardOutput $script:TranscribeOutputPath `
            -RedirectStandardError $script:TranscribeErrorPath `
            -PassThru
    }
    catch {
        $script:IsTranscribing = $false
        $startButton.Enabled = $true
        $stopButton.Enabled = $false
        Write-Log "Start-Transcription failed: $($_.Exception.Message)"
        Remove-PrivateArtifacts
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Voice Typer") | Out-Null
    }
}

function Complete-TranscriptionIfReady {
    if ($null -eq $script:TranscribeProcess -or -not $script:TranscribeProcess.HasExited) {
        return
    }

    $exitCode = $script:TranscribeProcess.ExitCode
    $script:TranscribeProcess.Dispose()
    $script:TranscribeProcess = $null
    $script:IsTranscribing = $false

    $raw = ""
    if (Test-Path -LiteralPath $script:TranscribeOutputPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $script:TranscribeOutputPath -Raw
    }
    $text = Get-FinalTranscriptText $raw

    if ([string]::IsNullOrWhiteSpace($text)) {
        $statusLabel.Text = "No speech"
        Write-Log "Transcription finished with no text. Exit=$exitCode"
    }
    else {
        $transcriptBox.AppendText($text + [Environment]::NewLine)
        if ($script:Config.AutoTypeAfterTranscribe) {
            Send-TextToTarget $text
        }
        $statusLabel.Text = "Typed"
        Write-Log "Transcription completed. Characters=$($text.Length)"
    }

    $startButton.Enabled = $true
    $stopButton.Enabled = $false
    Remove-PrivateArtifacts
}

function Get-FinalTranscriptText {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return ""
    }

    $lines = $Raw -split "\r\n|\n|\r"
    $clean = foreach ($line in $lines) {
        $item = Get-CleanTranscriptLine $line
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            $item
        }
    }

    return (($clean -join " ") -replace "\s+", " ").Trim()
}

function Get-HotkeyVirtualKey {
    $hotkey = [string](Get-ConfigValue -Config $script:Config -Name "Hotkey" -Default "F8")
    switch -Regex ($hotkey.ToUpperInvariant()) {
        "^F([1-9]|1[0-2])$" { return (111 + [int]$Matches[1]) }
        "^SPACE$" { return 32 }
        default { return 119 }
    }
}

function Toggle-Recording {
    if ($script:IsRecording) {
        Stop-VoiceRecording
    }
    elseif (-not $script:IsTranscribing) {
        Start-VoiceRecording
    }
}

function Offer-BackendSetup {
    param([string]$Reason)

    $setupPath = Join-Path $script:AppRoot "Install-VoiceTyperBackend.ps1"
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show($Reason, "Voice Typer", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $choice = [System.Windows.Forms.MessageBox]::Show(
        "$Reason`r`n`r`nRun the PowerShell setup helper now?",
        "Voice Typer",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process pwsh.exe -ArgumentList @(
            "-NoProfile",
            "-File", (Quote-Arg $setupPath)
        )
    }
}

function ConvertTo-SendKeysText {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Text.ToCharArray()) {
        switch ($char) {
            "`r" { break }
            "`n" { [void]$builder.Append("{ENTER}"); break }
            "`t" { [void]$builder.Append("{TAB}"); break }
            "{" { [void]$builder.Append("{{}"); break }
            "}" { [void]$builder.Append("{}}"); break }
            "+" { [void]$builder.Append("{+}"); break }
            "^" { [void]$builder.Append("{^}"); break }
            "%" { [void]$builder.Append("{%}"); break }
            "~" { [void]$builder.Append("{~}"); break }
            "(" { [void]$builder.Append("{(}"); break }
            ")" { [void]$builder.Append("{)}"); break }
            "[" { [void]$builder.Append("{[}"); break }
            "]" { [void]$builder.Append("{]}"); break }
            default { [void]$builder.Append($char) }
        }
    }
    return $builder.ToString()
}

function Paste-TextToTarget {
    param([string]$Text)

    $previousText = $null
    $hadText = $false
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $previousText = [System.Windows.Forms.Clipboard]::GetText()
            $hadText = $true
        }
    }
    catch {
        Write-Log "Clipboard read failed: $($_.Exception.Message)"
    }

    [System.Windows.Forms.Clipboard]::SetText($Text)
    Start-Sleep -Milliseconds 40
    [System.Windows.Forms.SendKeys]::SendWait("^v")
    Start-Sleep -Milliseconds 80

    try {
        if ($hadText) {
            [System.Windows.Forms.Clipboard]::SetText($previousText)
        }
        else {
            [System.Windows.Forms.Clipboard]::Clear()
        }
    }
    catch {
        Write-Log "Clipboard restore failed: $($_.Exception.Message)"
    }
}

function Send-TextToTarget {
    param([string]$Text)

    try {
        if ([string]::IsNullOrWhiteSpace($Text) -or -not $script:IsTypingEnabled) {
            return
        }

        if (-not (Resolve-TypingTarget)) {
            Write-Log "No usable typing target. Characters=$($Text.Length)"
            return
        }

        $foreground = [NativeWindowTools]::GetForegroundWindow()
        $mustRefocusFallback = ($foreground -ne $script:TargetHandle) -or (-not (Test-UsableTargetWindow $foreground))
        $shouldRefocus = $script:IsTargetLocked -or $script:Config.RefocusTargetBeforeTyping -or $mustRefocusFallback

        if ($script:TargetHandle -ne [IntPtr]::Zero -and $shouldRefocus) {
            [void][NativeWindowTools]::SetForegroundWindow($script:TargetHandle)
            Start-Sleep -Milliseconds 20
        }

        $outputMethod = [string](Get-ConfigValue -Config $script:Config -Name "OutputMethod" -Default "Paste")
        if ($outputMethod.Equals("Paste", [StringComparison]::OrdinalIgnoreCase)) {
            Paste-TextToTarget $Text
        }
        else {
            [System.Windows.Forms.SendKeys]::SendWait((ConvertTo-SendKeysText $Text))
        }
        $script:LastTypedAt = Get-Date
        Write-Log "$outputMethod into '$script:TargetTitle'. Characters=$($Text.Length)"
    }
    catch {
        Write-Log "Send-TextToTarget failed: $($_.Exception.Message)"
    }
}

function Get-CleanTranscriptLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return ""
    }

    $clean = $Line -replace "`e\[[0-?]*[ -/]*[@-~]", ""
    $clean = $clean -replace "^\s*\[[0-9:.]+\s*-->\s*[0-9:.]+\]\s*", ""
    $clean = $clean.Trim()

    if ($clean -match "^(whisper_|main:|system_info:|processing|sampling|init|error:|warning:|audio)") {
        return ""
    }
    if ($clean -match "^\[(Start speaking|BLANK_AUDIO)\]$") {
        return ""
    }
    if ($clean -match "^\s*\[.*\]\s*$") {
        return ""
    }
    if ($clean.Length -lt 2) {
        return ""
    }

    return $clean
}

function Get-TextDelta {
    param(
        [string]$Previous,
        [string]$Current
    )

    if ([string]::IsNullOrWhiteSpace($Current)) {
        return ""
    }
    if ([string]::IsNullOrWhiteSpace($Previous)) {
        return $Current
    }
    if ($Current.StartsWith($Previous, [StringComparison]::Ordinal)) {
        return $Current.Substring($Previous.Length)
    }
    if ($Previous.StartsWith($Current, [StringComparison]::Ordinal)) {
        return ""
    }

    $max = [Math]::Min($Previous.Length, $Current.Length)
    $prefix = 0
    while ($prefix -lt $max -and $Previous[$prefix] -eq $Current[$prefix]) {
        $prefix++
    }

    if ($prefix -ge 8) {
        return $Current.Substring($prefix)
    }

    $elapsed = ((Get-Date) - $script:LastTypedAt).TotalSeconds
    if ($elapsed -gt 1.5) {
        return $script:Config.TypeSeparator + $Current
    }

    return ""
}

function Build-WhisperArguments {
    $modelPath = Resolve-AppPath $script:Config.ModelPath
    $args = @(
        "-m", (Quote-Arg $modelPath),
        "-t", [string]$script:Config.Threads,
        "-l", [string]$script:Config.Language
    )

    if ($script:Config.UseVadMode) {
        $args += @("--step", "0", "--length", [string]$script:Config.LengthMs, "-vth", [string]$script:Config.VadThreshold)
    }
    else {
        $args += @("--step", [string]$script:Config.StepMs, "--length", [string]$script:Config.LengthMs)
    }

    $keepMs = [int](Get-ConfigValue -Config $script:Config -Name "KeepMs" -Default 100)
    if ($keepMs -gt 0) {
        $args += @("--keep", [string]$keepMs)
    }

    $maxTokens = [int](Get-ConfigValue -Config $script:Config -Name "MaxTokens" -Default 24)
    if ($maxTokens -gt 0) {
        $args += @("--max-tokens", [string]$maxTokens)
    }

    $audioContext = [int](Get-ConfigValue -Config $script:Config -Name "AudioContext" -Default 512)
    if ($audioContext -gt 0) {
        $args += @("--audio-ctx", [string]$audioContext)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:Config.ExtraArgs)) {
        $args += $script:Config.ExtraArgs
    }

    return ($args -join " ")
}

function Stop-Whisper {
    if ($null -ne $script:WhisperProcess) {
        try {
            if (-not $script:WhisperProcess.HasExited) {
                Write-Log "Stopping whisper process pid=$($script:WhisperProcess.Id)"
                $script:WhisperProcess.Kill()
                $script:WhisperProcess.WaitForExit(1500)
            }
        }
        catch {
            Write-Log "Stop-Whisper failed: $($_.Exception.Message)"
        }
        $script:WhisperProcess.Dispose()
        $script:WhisperProcess = $null
    }
    $script:OutputHandlers = @()
}

$script:Config = Load-Config

$form = New-Object System.Windows.Forms.Form
$form.Text = "Voice Typer"
$form.Size = New-Object System.Drawing.Size(300, 300)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.TopMost = $true
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(10, 8)
$statusLabel.Size = New-Object System.Drawing.Size(264, 20)
$statusLabel.Text = "Ready"

$targetLabel = New-Object System.Windows.Forms.Label
$targetLabel.Location = New-Object System.Drawing.Point(10, 32)
$targetLabel.Size = New-Object System.Drawing.Size(264, 34)
$targetLabel.Text = "Target: active app"

$pickButton = New-Object System.Windows.Forms.Button
$pickButton.Location = New-Object System.Drawing.Point(10, 72)
$pickButton.Size = New-Object System.Drawing.Size(82, 30)
$pickButton.Text = "Lock"

$startButton = New-Object System.Windows.Forms.Button
$startButton.Location = New-Object System.Drawing.Point(100, 72)
$startButton.Size = New-Object System.Drawing.Size(82, 30)
$startButton.Text = "Record"

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Location = New-Object System.Drawing.Point(190, 72)
$stopButton.Size = New-Object System.Drawing.Size(82, 30)
$stopButton.Text = "Stop"
$stopButton.Enabled = $false

$typeCheckBox = New-Object System.Windows.Forms.CheckBox
$typeCheckBox.Location = New-Object System.Drawing.Point(10, 108)
$typeCheckBox.Size = New-Object System.Drawing.Size(100, 22)
$typeCheckBox.Text = "Type output"
$typeCheckBox.Checked = $true

$topMostCheckBox = New-Object System.Windows.Forms.CheckBox
$topMostCheckBox.Location = New-Object System.Drawing.Point(118, 108)
$topMostCheckBox.Size = New-Object System.Drawing.Size(80, 22)
$topMostCheckBox.Text = "Topmost"
$topMostCheckBox.Checked = $true

$pasteCheckBox = New-Object System.Windows.Forms.CheckBox
$pasteCheckBox.Location = New-Object System.Drawing.Point(204, 108)
$pasteCheckBox.Size = New-Object System.Drawing.Size(68, 22)
$pasteCheckBox.Text = "Paste"
$pasteCheckBox.Checked = ([string](Get-ConfigValue -Config $script:Config -Name "OutputMethod" -Default "Paste")).Equals("Paste", [StringComparison]::OrdinalIgnoreCase)

$configButton = New-Object System.Windows.Forms.Button
$configButton.Location = New-Object System.Drawing.Point(204, 72)
$configButton.Size = New-Object System.Drawing.Size(68, 30)
$configButton.Text = "Config"

$transcriptBox = New-Object System.Windows.Forms.TextBox
$transcriptBox.Location = New-Object System.Drawing.Point(10, 138)
$transcriptBox.Size = New-Object System.Drawing.Size(262, 82)
$transcriptBox.Multiline = $true
$transcriptBox.ScrollBars = "Vertical"
$transcriptBox.ReadOnly = $true

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Location = New-Object System.Drawing.Point(10, 226)
$hintLabel.Size = New-Object System.Drawing.Size(264, 28)
$hintLabel.Text = "F8 toggles record/stop, then types final text."

$form.Controls.AddRange(@(
    $statusLabel, $targetLabel, $pickButton, $startButton, $stopButton,
    $typeCheckBox, $topMostCheckBox, $pasteCheckBox, $configButton, $transcriptBox, $hintLabel
))

$appendTranscript = {
    param([string]$Text)
    $transcriptBox.AppendText($Text + [Environment]::NewLine)
}

function Process-TranscriptLine {
    param([string]$Line)

    $text = Get-CleanTranscriptLine $Line
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    try {
        [void](Refresh-TargetForTranscript)
        & $appendTranscript $text
        $mode = [string]$script:Config.TypingMode
        if ($mode.Equals("Line", [StringComparison]::OrdinalIgnoreCase)) {
            Send-TextToTarget ($script:Config.TypeSeparator + $text)
            $script:LastTranscript = $text
        }
        else {
            $delta = Get-TextDelta -Previous $script:LastTranscript -Current $text
            if (-not [string]::IsNullOrWhiteSpace($delta)) {
                Send-TextToTarget $delta
            }
            $script:LastTranscript = $text
        }
    }
    catch {
        Write-Log "Process-TranscriptLine failed: $($_.Exception.Message)"
    }
}

function Process-WhisperDiagnosticLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    Write-Log "Whisper diagnostic received. Characters=$($Line.Length)"
    if ($Line -match "(?i)\b(error|failed|cannot|no capture|could not|exception)\b") {
        $statusLabel.Text = "Whisper diagnostic"
        & $appendTranscript ("[whisper] " + $Line.Trim())
    }
}

$pickButton.Add_Click({
    if ($script:IsTargetLocked) {
        $script:IsTargetLocked = $false
        $pickButton.Text = "Lock"
        $statusLabel.Text = "Auto target"
        $targetLabel.Text = "Target: active app"
        return
    }

    $seconds = [int]$script:Config.StartDelaySeconds
    $statusLabel.Text = "Optional lock: click target in $seconds sec..."
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(1, $seconds) * 1000
    $timer.Add_Tick({
        param($sender, $eventArgs)

        try {
            $sender.Stop()
            $sender.Dispose()

            if (Set-TargetFromForegroundWindow) {
                $script:IsTargetLocked = $true
                $pickButton.Text = "Unlock"
                $targetLabel.Text = "Target: " + $script:TargetTitle
                $statusLabel.Text = "Target locked"
            }
            else {
                $statusLabel.Text = "No target selected"
            }
        }
        catch {
            $statusLabel.Text = "Target failed"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Voice Typer") | Out-Null
        }
        finally {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            [void]$form.Activate()
        }
    })
    $timer.Start()
})

$startButton.Add_Click({
    $script:Config = Load-Config
    Update-DiscoveredBackendPaths
    $script:IsTypingEnabled = $typeCheckBox.Checked
    $script:LastTranscript = ""
    $script:LastTargetKey = ""
    $transcriptBox.Clear()

    $cliPath = Resolve-AppPath (Get-ConfigValue -Config $script:Config -Name "WhisperCliPath" -Default "")
    if (-not (Test-Path -LiteralPath $cliPath)) {
        Offer-BackendSetup "Cannot find whisper-cli.exe at the configured verified path."
        return
    }

    $modelPath = Resolve-AppPath $script:Config.ModelPath
    if (-not (Test-Path -LiteralPath $modelPath)) {
        Offer-BackendSetup "Cannot find the Whisper model at the configured verified path."
        return
    }

    Start-VoiceRecording
})

$stopButton.Add_Click({
    Stop-VoiceRecording
})

$typeCheckBox.Add_CheckedChanged({
    $script:IsTypingEnabled = $typeCheckBox.Checked
})

$pasteCheckBox.Add_CheckedChanged({
    if ($pasteCheckBox.Checked) {
        if ($script:Config.PSObject.Properties.Name -contains "OutputMethod") {
            $script:Config.OutputMethod = "Paste"
        }
        else {
            $script:Config | Add-Member -MemberType NoteProperty -Name "OutputMethod" -Value "Paste"
        }
    }
    else {
        if ($script:Config.PSObject.Properties.Name -contains "OutputMethod") {
            $script:Config.OutputMethod = "Type"
        }
        else {
            $script:Config | Add-Member -MemberType NoteProperty -Name "OutputMethod" -Value "Type"
        }
    }
    Save-Config -Config $script:Config
})

$topMostCheckBox.Add_CheckedChanged({
    $form.TopMost = $topMostCheckBox.Checked
})

$configButton.Add_Click({
    Save-Config -Config $script:Config
    Start-Process notepad.exe -ArgumentList (Quote-Arg $ConfigPath)
})

$whisperPollTimer = New-Object System.Windows.Forms.Timer
$whisperPollTimer.Interval = 100
$whisperPollTimer.Add_Tick({
    try {
        Complete-TranscriptionIfReady

        foreach ($line in (Read-NewLogLines -Path $script:WhisperStdoutPath -Offset ([ref]$script:WhisperStdoutOffset))) {
            Process-TranscriptLine $line
        }

        foreach ($line in (Read-NewLogLines -Path $script:WhisperStderrPath -Offset ([ref]$script:WhisperStderrOffset))) {
            Process-WhisperDiagnosticLine $line
        }

        if ($null -ne $script:WhisperProcess -and $script:WhisperProcess.HasExited) {
            foreach ($line in (Read-NewLogLines -Path $script:WhisperStdoutPath -Offset ([ref]$script:WhisperStdoutOffset))) {
                Process-TranscriptLine $line
            }
            foreach ($line in (Read-NewLogLines -Path $script:WhisperStderrPath -Offset ([ref]$script:WhisperStderrOffset))) {
                Process-WhisperDiagnosticLine $line
            }

            $exitCode = $script:WhisperProcess.ExitCode
            Write-Log "Whisper exited with code $exitCode"
            $script:WhisperProcess.Dispose()
            $script:WhisperProcess = $null
            $startButton.Enabled = $true
            $stopButton.Enabled = $false
            $statusLabel.Text = "Whisper exited ($exitCode)"
        }
    }
    catch {
        Write-Log "whisperPollTimer failed: $($_.Exception.Message)"
        $statusLabel.Text = "Poll error"
        if ($null -eq $script:TranscribeProcess -or $script:TranscribeProcess.HasExited) {
            Remove-PrivateArtifacts
        }
    }
})
$whisperPollTimer.Start()

$hotkeyTimer = New-Object System.Windows.Forms.Timer
$hotkeyTimer.Interval = 80
$hotkeyTimer.Add_Tick({
    try {
        $vk = Get-HotkeyVirtualKey
        $isDown = ([NativeWindowTools]::GetAsyncKeyState($vk) -band 0x8000) -ne 0
        if ($isDown -and -not $script:HotkeyWasDown) {
            Toggle-Recording
        }
        $script:HotkeyWasDown = $isDown
    }
    catch {
        Write-Log "hotkeyTimer failed: $($_.Exception.Message)"
    }
})
$hotkeyTimer.Start()

$targetWatchTimer = New-Object System.Windows.Forms.Timer
$targetWatchTimer.Interval = 350
$targetWatchTimer.Add_Tick({
    try {
        if ($script:IsTargetLocked) {
            return
        }

        $mode = [string](Get-ConfigValue -Config $script:Config -Name "TargetMode" -Default "ActiveWindow")
        if ($mode.Equals("Locked", [StringComparison]::OrdinalIgnoreCase)) {
            return
        }

        $foreground = [NativeWindowTools]::GetForegroundWindow()
        if (Test-UsableTargetWindow $foreground) {
            Set-TargetWindow -Handle $foreground
            $targetLabel.Text = "Target: " + $script:TargetTitle
        }
    }
    catch {
        Write-Log "targetWatchTimer failed: $($_.Exception.Message)"
    }
})
$targetWatchTimer.Start()

$form.Add_FormClosing({
    Write-Log "VoiceTyper closing"
    if ($script:IsRecording) {
        try { [void]$script:Recorder.Stop() } catch {}
    }
    $hotkeyTimer.Stop()
    $hotkeyTimer.Dispose()
    $whisperPollTimer.Stop()
    $whisperPollTimer.Dispose()
    $targetWatchTimer.Stop()
    $targetWatchTimer.Dispose()
    Stop-Whisper
    Remove-PrivateArtifacts
})

[void]$form.ShowDialog()
