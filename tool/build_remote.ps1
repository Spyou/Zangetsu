# Builds the review APK using sibling workspace toolchains and optional device tests.
# Let Flutter refresh release plugin registration; --no-pub can leave test plugins registered.
param([switch]$WithDeviceTests)
$ErrorActionPreference = 'Stop'
$remoteProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$remoteWork = Split-Path $remoteProject -Parent
$remoteWorkspace = Split-Path $remoteWork -Parent
$env:PUB_CACHE = Join-Path $remoteWork 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $remoteWork 'gradle-cache'
$env:JAVA_HOME = Join-Path ${env:ProgramFiles} 'Android/Android Studio/jbr'
$remoteFlutter = Join-Path $remoteWork 'flutter/bin/flutter.bat'
if (!(Test-Path -LiteralPath $remoteFlutter)) { throw 'Workspace Flutter SDK is missing.' }
Push-Location $remoteProject
try {
    & $remoteFlutter build apk --release --target-platform android-arm,android-arm64
    if ($LASTEXITCODE -ne 0) { throw 'Remote APK build failed.' }
    $remoteOutputs = Join-Path $remoteWorkspace 'outputs'
    New-Item -ItemType Directory -Force -Path $remoteOutputs | Out-Null
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-release.apk' -Destination (Join-Path $remoteOutputs 'Zangetsu-review.apk')
    if ($WithDeviceTests) {
        Push-Location android
        try {
            & './gradlew.bat' :app:assembleDebugAndroidTest '-Ptarget-platform=android-arm,android-arm64' --console=plain --max-workers=8
            if ($LASTEXITCODE -ne 0) { throw 'Device test APK build failed.' }
        } finally { Pop-Location }
    }
} finally { Pop-Location }
