$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

# Tool locations are resolved from the environment, never hardcoded: this file
# lives in a public repository, so a machine-specific user name must not leak
# into it.
if (-not $env:ANDROID_HOME) {
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $sdk) { $env:ANDROID_HOME = $sdk }
}
if ($env:ANDROID_HOME) { $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME }

# lanpub invokes Windows PowerShell; use its modules even from a pwsh host.
$env:PSModulePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$env:PYTHONIOENCODING = 'utf-8'

$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
$flutter = if ($flutterCmd) { $flutterCmd.Source } else { $null }
if (-not $flutter) {
    $fallback = Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'
    if (Test-Path $fallback) { $flutter = $fallback }
}
if (-not $flutter) { throw 'flutter not found: put it on PATH, or install it to ~/flutter' }

$pubspec = Join-Path $PWD 'pubspec.yaml'
$content = [IO.File]::ReadAllText($pubspec)
$version = [regex]::Match($content, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)')
if (-not $version.Success) { throw 'Cannot parse pubspec.yaml version' }
$name = '{0}.{1}.{2}' -f $version.Groups[1].Value, $version.Groups[2].Value, ([int]$version.Groups[3].Value + 1)
$code = [int]$version.Groups[4].Value + 1
[IO.File]::WriteAllText($pubspec, $content.Replace($version.Value, "version: $name+$code"))
Write-Host "==> Building $name+$code for LAN publication"

& $flutter build apk --release --flavor normal
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$apk = 'build/app/outputs/flutter-apk/app-normal-release.apk'
& lanpub add $apk
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "==> Published $name+$code to the LAN repository"
