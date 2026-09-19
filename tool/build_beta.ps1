param([switch]$WithDeviceTests)
$ErrorActionPreference = 'Stop'
$betaProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$betaWork = Split-Path $betaProject -Parent
$betaWorkspace = Split-Path $betaWork -Parent
$env:PUB_CACHE = Join-Path $betaWork 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $betaWork 'gradle-cache'
$env:JAVA_HOME = Join-Path ${env:ProgramFiles} 'Android/Android Studio/jbr'
$betaFlutter = Join-Path $betaWork 'flutter/bin/flutter.bat'
if (!(Test-Path -LiteralPath $betaFlutter)) { throw 'Workspace Flutter SDK is missing.' }
Push-Location $betaProject
try {
    & $betaFlutter build apk --release --no-pub --target-platform android-arm,android-arm64
    if ($LASTEXITCODE -ne 0) { throw 'Beta APK build failed.' }
    $betaOutputs = Join-Path $betaWorkspace 'outputs'
    New-Item -ItemType Directory -Force -Path $betaOutputs | Out-Null
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-release.apk' -Destination (Join-Path $betaOutputs 'Zangetsu-review.apk')
    if ($WithDeviceTests) {
        Push-Location android
        try {
            & './gradlew.bat' :app:assembleDebugAndroidTest '-Ptarget-platform=android-arm,android-arm64' --console=plain --max-workers=8
            if ($LASTEXITCODE -ne 0) { throw 'Device test APK build failed.' }
        } finally { Pop-Location }
    }
} finally { Pop-Location }
