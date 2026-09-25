# ObtainAPK build recipes (project lives in ./ — working-directory is current dir)
#
# Usage:
#   just release     Bump version (patch+1, build+1) + build + rename APK
#   just build       Build WITHOUT bumping version (same version as last build)
#   just bump        Only bump patch + build number, no build
#   just pub-get     Fetch Flutter/Dart deps
#   just clean       flutter clean (only when things are weird)
#   just clean-all   flutter clean + nuke Gradle caches (AGP/Gradle upgrades)
#   just install     Install built APK to a connected device
#
# Signing: provide android/key.properties before building. See README or
# android/app/build.gradle.kts for the expected format. A debug keystore at
# ~/.android/debug.keystore works for local testing.
#
# Versioning: version line in pubspec.yaml is `x.y.z+nnnn`. `just bump`
# increments patch and build number, writes back to pubspec.yaml, and prints
# the new version string. `just release` calls bump then builds.

# Windows shell: no profile (user's has broken Terminal-Icons), call flutter.bat
# by absolute path so this works regardless of global PATH.
#
# IMPORTANT: each recipe line starts a FRESH PowerShell process on Windows,
# so all logic for one recipe must be on a SINGLE line (separated by ;).
set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

# Absolute paths — change these when moving machines
FLUTTER_BAT := "C:\\Users\\ted\\flutter\\bin\\flutter.bat"
ANDROID_SDK  := "C:\\Users\\ted\\AppData\\Local\\Android\\Sdk"
PUBSPEC      := "pubspec.yaml"
APK_OUT      := "build\\app\\outputs\\flutter-apk\\app-normal-release.apk"

# ---- Dependency management ----
pub-get:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' pub get

# ---- Version bump ----
# Reads `version: x.y.z+nnnn` from pubspec.yaml, bumps patch (z+1) and build
# number (nnnn+1), writes back, prints the new version.
bump:
	$content = Get-Content '{{PUBSPEC}}' -Raw; $m = [regex]::Match($content, 'version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)'); if (-not $m.Success) { throw "Cannot parse version line in {{PUBSPEC}}" }; $mj=[int]$m.Groups[1].Value; $mn=[int]$m.Groups[2].Value; $mp=[int]$m.Groups[3].Value+1; $mb=[int]$m.Groups[4].Value+1; $newv = "${mj}.${mn}.${mp}+${mb}"; $content = $content -replace [regex]::Escape($m.Value), "version: $newv"; [IO.File]::WriteAllText('{{PUBSPEC}}', $content); Write-Host "==> version bumped: $($m.Groups[0].Value.Trim()) -> $newv" -ForegroundColor Cyan

# ---- Build ----
# Plain build — does NOT bump version. Use this when you want to rebuild
# the same version number (e.g. after fixing a build error).
build:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; $t=Get-Date; Write-Host "==> 开始构建 $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan; & '{{FLUTTER_BAT}}' build apk --release --flavor normal; if ($LASTEXITCODE -eq 0) { Write-Host "==> 构建成功! 用时 $([math]::Round(((Get-Date)-$t).TotalMinutes,1)) 分钟" -ForegroundColor Green; Write-Host "==> APK: {{APK_OUT}}" -ForegroundColor Green; [System.Media.SystemSounds]::Exclamation.Play() } else { Write-Host "==> 构建失败 (exit $LASTEXITCODE)" -ForegroundColor Red; [System.Media.SystemSounds]::Hand.Play() }

# ---- Release ----
# Bump patch+build, then build, then rename APK to include version.
# The published version is clean ("1.6.32") — the "+build" part stays only in
# pubspec.yaml as the internal Android versionCode, never in the APK name.
# Example output: build\app\outputs\flutter-apk\obtainapk-v1.6.19.apk
release:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; $content = Get-Content '{{PUBSPEC}}' -Raw; $m = [regex]::Match($content, 'version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)'); if (-not $m.Success) { throw "Cannot parse version line in {{PUBSPEC}}" }; $mj=[int]$m.Groups[1].Value; $mn=[int]$m.Groups[2].Value; $mp=[int]$m.Groups[3].Value+1; $mb=[int]$m.Groups[4].Value+1; $relv = "${mj}.${mn}.${mp}"; $newv = "${relv}+${mb}"; $content = $content -replace [regex]::Escape($m.Value), "version: $newv"; [IO.File]::WriteAllText('{{PUBSPEC}}', $content); Write-Host "==> version bumped: $($m.Groups[0].Value.Trim()) -> $newv" -ForegroundColor Cyan; $t=Get-Date; & '{{FLUTTER_BAT}}' build apk --release --flavor normal; if ($LASTEXITCODE -ne 0) { Write-Host "==> 构建失败 (exit $LASTEXITCODE)" -ForegroundColor Red; [System.Media.SystemSounds]::Hand.Play(); exit 1 }; $src = '{{APK_OUT}}'; $dstDir = Split-Path $src; $dst = Join-Path $dstDir "obtainapk-v$relv.apk"; if (Test-Path $src) { Move-Item -Force $src $dst; Write-Host "==> APK: $dst" -ForegroundColor Green } else { Write-Host "==> 构建完成但找不到 APK at $src" -ForegroundColor Yellow }; Write-Host "==> 构建成功! 用时 $([math]::Round(((Get-Date)-$t).TotalMinutes,1)) 分钟" -ForegroundColor Green; [System.Media.SystemSounds]::Exclamation.Play()

# ---- Clean ----
clean:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' clean; Write-Host "==> 已清理" -ForegroundColor Yellow

# Nuke Gradle caches too — for when you switch AGP / Gradle versions.
clean-all:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' clean; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\build-cache-*" -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\transforms-*" -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\modules-2" -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\kotlin" -ErrorAction SilentlyContinue; Write-Host "==> Gradle 缓存已清除" -ForegroundColor Yellow

# ---- Install ----
install device='':
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' install --use-application-binary build/app/outputs/flutter-apk/app-normal-release.apk {{ if device != '' { '--device-id ' + device } else { '' } }}

# Default target: release (bump + build + rename)
default: release
