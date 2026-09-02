param(
    [ValidateSet("base.en")]
    [string]$ModelName = "base.en",
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$appRoot = Split-Path -Parent $PSCommandPath
$vendorRoot = Join-Path $appRoot "vendor"
$modelsRoot = Join-Path $appRoot "models"
$configPath = Join-Path $appRoot "VoiceTyper.config.json"

# Reviewed immutable inputs. Updating either dependency requires a code review
# that changes both the source revision and its published SHA-256 digest.
$whisperReleaseTag = "b4938"
$whisperAssetName = "whisper-bin-x64.zip"
$whisperAssetSha256 = "c2a4b60edb11f7e11a9191ffb50929535527d4d91c9903dbe3e554583bbbc63d"
$whisperAssetUrl = "https://github.com/ggml-org/whisper.cpp/releases/download/$whisperReleaseTag/$whisperAssetName"
$whisperInstallRoot = Join-Path $vendorRoot "whisper-$whisperReleaseTag"
$modelManifest = @{
    "base.en" = @{
        Revision = "80da2d8bfee42b0e836fc3a9890373e5defc00a6"
        Sha256 = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
    }
}

New-Item -ItemType Directory -Force -Path $vendorRoot, $modelsRoot | Out-Null

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

function Get-Config {
    if (Test-Path -LiteralPath $configPath) {
        return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }

    return [pscustomobject]@{
        WhisperStreamPath = ".\vendor\whisper-$whisperReleaseTag\Release\whisper-stream.exe"
        WhisperCliPath = ".\vendor\whisper-$whisperReleaseTag\Release\whisper-cli.exe"
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

function Set-ConfigValue {
    param(
        [object]$Config,
        [string]$Name,
        [object]$Value
    )
    if ($Config.PSObject.Properties.Name -contains $Name) {
        $Config.$Name = $Value
    }
    else {
        $Config | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Save-Config {
    param([object]$Config)
    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

function Assert-FileSha256 {
    param(
        [string]$Path,
        [string]$ExpectedSha256
    )

    if ($ExpectedSha256 -notmatch "^[0-9a-f]{64}$") {
        throw "Expected SHA-256 must contain exactly 64 lowercase hexadecimal characters."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256) {
        throw "SHA-256 verification failed for $(Split-Path -Leaf $Path). Expected $ExpectedSha256; received $actual."
    }
}

function Download-VerifiedFile {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$ExpectedSha256
    )

    if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
        Assert-FileSha256 -Path $OutFile -ExpectedSha256 $ExpectedSha256
        Write-Host "Verified existing file: $OutFile" -ForegroundColor Green
        return
    }

    $temporary = "$OutFile.download"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    try {
        Write-Host "Downloading verified source: $Url"
        Invoke-WebRequest -Uri $Url -OutFile $temporary -UseBasicParsing
        Assert-FileSha256 -Path $temporary -ExpectedSha256 $ExpectedSha256
        Move-Item -LiteralPath $temporary -Destination $OutFile
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Install-PinnedWhisper {
    $archivePath = Join-Path $vendorRoot $whisperAssetName
    Download-VerifiedFile -Url $whisperAssetUrl -OutFile $archivePath -ExpectedSha256 $whisperAssetSha256

    if ((Split-Path -Parent $whisperInstallRoot) -ne $vendorRoot) {
        throw "Refusing to replace a Whisper directory outside the application vendor root."
    }
    if (Test-Path -LiteralPath $whisperInstallRoot) {
        $existingInstall = Get-Item -LiteralPath $whisperInstallRoot -Force
        if (($existingInstall.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to replace a Whisper directory through a reparse point."
        }
        Remove-Item -LiteralPath $whisperInstallRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $whisperInstallRoot | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $whisperInstallRoot

    $releaseRoot = Join-Path $whisperInstallRoot "Release"
    $streamPath = Join-Path $releaseRoot "whisper-stream.exe"
    $cliPath = Join-Path $releaseRoot "whisper-cli.exe"
    $sdlPath = Join-Path $releaseRoot "SDL2.dll"
    foreach ($required in @($streamPath, $cliPath, $sdlPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Verified Whisper archive is missing required file: $required"
        }
    }

    return [pscustomobject]@{
        StreamPath = $streamPath
        CliPath = $cliPath
    }
}

$config = Get-Config

Write-Step "Installing pinned whisper.cpp $whisperReleaseTag"
$whisper = Install-PinnedWhisper
Set-ConfigValue -Config $config -Name "WhisperStreamPath" -Value $whisper.StreamPath
Set-ConfigValue -Config $config -Name "WhisperCliPath" -Value $whisper.CliPath
Write-Host "Verified stream: $($whisper.StreamPath)" -ForegroundColor Green
Write-Host "Verified CLI: $($whisper.CliPath)" -ForegroundColor Green

Write-Step "Checking pinned Whisper model"
$modelRecord = $modelManifest[$ModelName]
$modelFile = "ggml-$ModelName.bin"
$modelPath = Join-Path $modelsRoot $modelFile
$modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/$($modelRecord.Revision)/$modelFile"
Download-VerifiedFile -Url $modelUrl -OutFile $modelPath -ExpectedSha256 $modelRecord.Sha256
Set-ConfigValue -Config $config -Name "ModelPath" -Value $modelPath
Write-Host "Verified model: $modelPath" -ForegroundColor Green

Set-ConfigValue -Config $config -Name "TargetMode" -Value "ActiveWindow"
Set-ConfigValue -Config $config -Name "PreferredTargetTitle" -Value "Codex"
Set-ConfigValue -Config $config -Name "Mode" -Value "PushToTalk"
Set-ConfigValue -Config $config -Name "Hotkey" -Value "F8"
Set-ConfigValue -Config $config -Name "AutoTypeAfterTranscribe" -Value $true
Set-ConfigValue -Config $config -Name "OutputMethod" -Value "Paste"
Set-ConfigValue -Config $config -Name "EnableFeedbackSounds" -Value $true
Set-ConfigValue -Config $config -Name "RecordStartSound" -Value "Asterisk"
Set-ConfigValue -Config $config -Name "RecordStopSound" -Value "Exclamation"
Set-ConfigValue -Config $config -Name "PreserveDebugArtifacts" -Value $false
Save-Config -Config $config

Write-Step "Done"
Write-Host "Config updated: $configPath"
Write-Host "Restart VoiceTyper or click Start again."
if (-not $NoPause) {
    Read-Host "Press Enter to close"
}
