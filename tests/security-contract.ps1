Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoRoot "Install-VoiceTyperBackend.ps1"
$appPath = Join-Path $repoRoot "VoiceTyper.ps1"
$installer = Get-Content -LiteralPath $installerPath -Raw
$app = Get-Content -LiteralPath $appPath -Raw

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -match $Pattern) {
        throw $Message
    }
}

foreach ($path in @($installerPath, $appPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "$path has PowerShell parse errors: $($parseErrors[0].Message)"
    }
}

Assert-Match $installer '\$whisperReleaseTag\s*=\s*"b\d+"' "Whisper release must be an exact reviewed tag."
Assert-Match $installer '\$whisperAssetSha256\s*=\s*"[0-9a-f]{64}"' "Whisper archive must have a pinned SHA-256."
Assert-Match $installer 'Revision\s*=\s*"[0-9a-f]{40}"' "Model source must use an immutable revision."
Assert-Match $installer 'Sha256\s*=\s*"[0-9a-f]{64}"' "Model source must have a pinned SHA-256."
Assert-Match $installer 'Assert-FileSha256' "Every external file must pass the shared digest gate."
Assert-NoMatch $installer 'releases/latest|resolve/main|git\s+clone|git\s+pull|Invoke-RestMethod|Build-WhisperStream' "Mutable dependency discovery/build fallbacks must stay deleted."

Assert-Match $app 'PreserveDebugArtifacts\s*=\s*\$false' "Private artifacts must be ephemeral by default."
Assert-Match $app 'Remove-PrivateArtifacts' "Private artifact cleanup must remain active."
Assert-NoMatch $app 'Transcription text:|for text:\s*\$Text|TargetTitle''\s*:\s*\$Text' "Transcript text must never be written to the application log."
Assert-NoMatch $app 'ExecutionPolicy"\s*,\s*"Bypass|powershell\.exe' "The app must not bypass execution policy or fall back to Windows PowerShell."

Write-Host "VoiceTyper security contract: PASS"
