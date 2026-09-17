# ObtainAPK build recipes (project lives in ./ — working-directory is current dir)
#
# Usage:
#   just build       Build the signed release APK
#   just pub-get     Fetch Flutter/Dart deps
#   just clean       flutter clean (only when things are weird)
#   just clean-all   flutter clean + nuke Gradle caches (AGP/Gradle upgrades)
#   just install     Install built APK to connected device
#
# Signing: provide android/key.properties before building. See README or
# android/app/build.gradle.kts for the expected format. A debug keystore at
# ~/.android/debug.keystore works for local testing.

# Windows shell: no profile (user's has broken Terminal-Icons), call flutter.bat
# by absolute path so this works regardless of global PATH.
#
# IMPORTANT: each recipe line starts a FRESH PowerShell process on Windows,
# so all logic for one recipe must be on a SINGLE line (separated by ;).
set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

# Absolute paths — change these when moving machines
FLUTTER_BAT := "C:\\Users\\ted\\flutter\\bin\\flutter.bat"
ANDROID_SDK  := "C:\\Users\\ted\\AppData\\Local\\Android\\Sdk"

# ---- Dependency management ----
pub-get:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' pub get

# ---- Build ----
# Incremental: Gradle + Dart AOT caches give fast rebuilds after the first compile.
# Only run `just clean` when builds behave weirdly — it nukes .dart_tool/ and build/.
build:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; $t=Get-Date; Write-Host "==> 开始构建 $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan; & '{{FLUTTER_BAT}}' build apk --release --flavor normal; if ($LASTEXITCODE -eq 0) { Write-Host "==> 构建成功! 用时 $([math]::Round(((Get-Date)-$t).TotalMinutes,1)) 分钟" -ForegroundColor Green; Write-Host "==> APK: build\app\outputs\flutter-apk\app-normal-release.apk" -ForegroundColor Green; [System.Media.SystemSounds]::Exclamation.Play() } else { Write-Host "==> 构建失败 (exit $LASTEXITCODE)" -ForegroundColor Red; [System.Media.SystemSounds]::Hand.Play() }

# ---- Clean ----
clean:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' clean; Write-Host "==> 已清理" -ForegroundColor Yellow

# Nuke Gradle caches too — for when you switch AGP / Gradle versions.
clean-all:
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' clean; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\build-cache-*" -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\transforms-*" -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\modules-2" -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\kotlin" -ErrorAction SilentlyContinue; Write-Host "==> Gradle 缓存已清除" -ForegroundColor Yellow

# ---- Install ----
install device='':
	$env:ANDROID_HOME='{{ANDROID_SDK}}'; $env:ANDROID_SDK_ROOT='{{ANDROID_SDK}}'; & '{{FLUTTER_BAT}}' install --use-application-binary build/app/outputs/flutter-apk/app-normal-release.apk {{ if device != '' { '--device-id ' + device } else { '' } }}

# Default target
default: build
