param(
    [string]$ModelName = "base.en",
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$appRoot = Split-Path -Parent $PSCommandPath
$vendorRoot = Join-Path $appRoot "vendor"
$modelsRoot = Join-Path $appRoot "models"
$configPath = Join-Path $appRoot "VoiceTyper.config.json"

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
        WhisperStreamPath = ".\vendor\whisper.cpp\build\bin\Release\whisper-stream.exe"
        WhisperCliPath = ".\vendor\whisper.cpp-build\bin\Release\whisper-cli.exe"
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

function Find-WhisperStream {
    $match = Get-ChildItem -LiteralPath $vendorRoot -Recurse -File -Filter "whisper-stream.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $match) {
        return $match.FullName
    }

    $command = Get-Command "whisper-stream.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    return ""
}

function Find-WhisperCli {
    $match = Get-ChildItem -LiteralPath $vendorRoot -Recurse -File -Filter "whisper-cli.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $match) {
        return $match.FullName
    }

    $command = Get-Command "whisper-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    return ""
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutFile
    )
    Write-Host $Url
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $appRoot
    )

    Write-Host "> $FilePath $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Get-VisualStudioGenerator {
    $help = cmake --help
    foreach ($candidate in @("Visual Studio 18 2026", "Visual Studio 17 2022", "Visual Studio 16 2019")) {
        if ($help -match [regex]::Escape($candidate)) {
            return $candidate
        }
    }
    return ""
}

function Test-VisualCppInstalled {
    $vswhereCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
    )

    foreach ($candidate in $vswhereCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $installPath = & $candidate -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
            if (-not [string]::IsNullOrWhiteSpace($installPath)) {
                return $true
            }
        }
    }

    return $false
}

function Get-LatestSdl2DevelAsset {
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/libsdl-org/SDL/releases?per_page=50" -Headers @{ "User-Agent" = "VoiceTyper-Setup" }
    foreach ($release in $releases) {
        if ($release.tag_name -notmatch "^release-2\.") {
            continue
        }

        $asset = $release.assets |
            Where-Object { $_.name -match "^SDL2-devel-.*-VC\.zip$" } |
            Select-Object -First 1
        if ($null -ne $asset) {
            return $asset
        }
    }

    return $null
}

function Install-Sdl2 {
    $sdlRoot = Join-Path $vendorRoot "SDL2"
    $existingConfig = Get-ChildItem -LiteralPath $sdlRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("SDL2Config.cmake", "sdl2-config.cmake") } |
        Select-Object -First 1
    if ($null -ne $existingConfig) {
        return (Split-Path -Parent $existingConfig.FullName)
    }

    Write-Step "Downloading SDL2 development package"
    $asset = Get-LatestSdl2DevelAsset
    if ($null -eq $asset) {
        throw "Could not find an SDL2-devel VC zip release."
    }

    $zipPath = Join-Path $vendorRoot $asset.name
    Download-File -Url $asset.browser_download_url -OutFile $zipPath
    New-Item -ItemType Directory -Force -Path $sdlRoot | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $sdlRoot -Force

    $config = Get-ChildItem -LiteralPath $sdlRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("SDL2Config.cmake", "sdl2-config.cmake") } |
        Select-Object -First 1
    if ($null -eq $config) {
        throw "SDL2 package downloaded, but no SDL2 CMake config was found."
    }

    return (Split-Path -Parent $config.FullName)
}

function Copy-SdlRuntime {
    param([string]$WhisperExePath)

    $sdlDll = Get-ChildItem -LiteralPath (Join-Path $vendorRoot "SDL2") -Recurse -File -Filter "SDL2.dll" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\" } |
        Select-Object -First 1
    if ($null -eq $sdlDll) {
        $sdlDll = Get-ChildItem -LiteralPath (Join-Path $vendorRoot "SDL2") -Recurse -File -Filter "SDL2.dll" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }

    if ($null -ne $sdlDll) {
        Copy-Item -LiteralPath $sdlDll.FullName -Destination (Split-Path -Parent $WhisperExePath) -Force
    }
}

function Build-WhisperStream {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is required to build whisper.cpp."
    }
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
        throw "CMake is required to build whisper.cpp."
    }
    if (-not (Test-VisualCppInstalled)) {
        throw "Visual Studio C++ build tools are required. Install the Desktop development with C++ workload, then run this setup again."
    }

    $generator = Get-VisualStudioGenerator
    if ([string]::IsNullOrWhiteSpace($generator)) {
        throw "CMake did not report a usable Visual Studio generator."
    }

    $sourceRoot = Join-Path $vendorRoot "whisper.cpp-src"
    $buildRoot = Join-Path $vendorRoot "whisper.cpp-build"
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        Write-Step "Cloning whisper.cpp"
        Invoke-Native -FilePath "git" -Arguments @("clone", "--depth", "1", "https://github.com/ggml-org/whisper.cpp.git", $sourceRoot)
    }
    else {
        Write-Step "Updating whisper.cpp"
        Invoke-Native -FilePath "git" -Arguments @("-C", $sourceRoot, "pull", "--ff-only")
    }

    $sdlConfigDir = Install-Sdl2

    Write-Step "Configuring whisper.cpp"
    Invoke-Native -FilePath "cmake" -Arguments @(
        "-S", $sourceRoot,
        "-B", $buildRoot,
        "-G", $generator,
        "-A", "x64",
        "-DWHISPER_SDL2=ON",
        "-DWHISPER_BUILD_EXAMPLES=ON",
        "-DSDL2_DIR=$sdlConfigDir"
    )

    Write-Step "Building whisper-stream.exe"
    Invoke-Native -FilePath "cmake" -Arguments @("--build", $buildRoot, "--config", "Release", "--target", "whisper-stream")
    Write-Step "Building whisper-cli.exe"
    Invoke-Native -FilePath "cmake" -Arguments @("--build", $buildRoot, "--config", "Release", "--target", "whisper-cli")

    $built = Get-ChildItem -LiteralPath $buildRoot -Recurse -File -Filter "whisper-stream.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $built) {
        throw "Build completed, but whisper-stream.exe was not found under $buildRoot."
    }

    Copy-SdlRuntime -WhisperExePath $built.FullName
    return $built.FullName
}

$config = Get-Config

Write-Step "Checking for whisper-stream.exe"
$whisperPath = Find-WhisperStream
$cliPath = Find-WhisperCli

if ([string]::IsNullOrWhiteSpace($whisperPath) -or [string]::IsNullOrWhiteSpace($cliPath)) {
    Write-Step "Trying to download a prebuilt Windows whisper.cpp release"
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest" -Headers @{ "User-Agent" = "VoiceTyper-Setup" }
    $asset = $release.assets |
        Where-Object {
            $_.name -match "(?i)(win|windows)" -and
            $_.name -match "(?i)(x64|amd64)" -and
            $_.name -match "\.zip$" -and
            $_.name -notmatch "(?i)(cuda|vulkan|openvino|sycl)"
        } |
        Select-Object -First 1

    if ($null -ne $asset) {
        $zipPath = Join-Path $vendorRoot $asset.name
        Download-File -Url $asset.browser_download_url -OutFile $zipPath
        $extractPath = Join-Path $vendorRoot "whisper.cpp"
        New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        $whisperPath = Find-WhisperStream
        $cliPath = Find-WhisperCli
    }
    else {
        Write-Host "No suitable prebuilt Windows x64 whisper.cpp release asset was found." -ForegroundColor Yellow
        Write-Host "Building whisper.cpp locally instead." -ForegroundColor Yellow
    }
}

if ([string]::IsNullOrWhiteSpace($whisperPath) -or [string]::IsNullOrWhiteSpace($cliPath)) {
    $whisperPath = Build-WhisperStream
    $cliPath = Find-WhisperCli
}

if (-not [string]::IsNullOrWhiteSpace($whisperPath)) {
    Set-ConfigValue -Config $config -Name "WhisperStreamPath" -Value $whisperPath
    Write-Host "Found: $whisperPath" -ForegroundColor Green
}

if (-not [string]::IsNullOrWhiteSpace($cliPath)) {
    Set-ConfigValue -Config $config -Name "WhisperCliPath" -Value $cliPath
    Write-Host "Found CLI: $cliPath" -ForegroundColor Green
}

Write-Step "Checking Whisper model"
$modelFile = "ggml-$ModelName.bin"
$modelPath = Join-Path $modelsRoot $modelFile
if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
    $modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$modelFile"
    Download-File -Url $modelUrl -OutFile $modelPath
}

if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
    Set-ConfigValue -Config $config -Name "ModelPath" -Value $modelPath
    Write-Host "Model: $modelPath" -ForegroundColor Green
}

Set-ConfigValue -Config $config -Name "TargetMode" -Value "ActiveWindow"
Set-ConfigValue -Config $config -Name "PreferredTargetTitle" -Value "Codex"
Set-ConfigValue -Config $config -Name "Mode" -Value "PushToTalk"
Set-ConfigValue -Config $config -Name "Hotkey" -Value "F8"
Set-ConfigValue -Config $config -Name "AutoTypeAfterTranscribe" -Value $true
Set-ConfigValue -Config $config -Name "OutputMethod" -Value "Paste"
Set-ConfigValue -Config $config -Name "EnableFeedbackSounds" -Value $true
Set-ConfigValue -Config $config -Name "RecordStartSound" -Value "Asterisk"
Set-ConfigValue -Config $config -Name "RecordStopSound" -Value "Exclamation"
Save-Config -Config $config

Write-Step "Done"
Write-Host "Config updated: $configPath"
Write-Host "Restart VoiceTyper or click Start again."
if (-not $NoPause) {
    Read-Host "Press Enter to close"
}
