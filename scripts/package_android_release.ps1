param(
    [switch]$SkipBuild,
    [switch]$Universal,
    [switch]$Arm64Only,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PubspecPath = Join-Path $RepoRoot 'pubspec.yaml'
$Version = 'dev'
if (Test-Path -LiteralPath $PubspecPath) {
    $versionLine = Get-Content -LiteralPath $PubspecPath -Encoding UTF8 |
        Where-Object { $_ -match '^version:\s*([^\s+#]+)' } |
        Select-Object -First 1
    if ($versionLine -and ($versionLine -match '^version:\s*([^\s+#]+)')) {
        $Version = $Matches[1].Trim()
    }
}

if (-not $SkipBuild) {
    $BuildArgs = @('build', 'apk', '--release')
    if (-not $Universal) {
        $BuildArgs += '--split-per-abi'
    }
    Write-Host "[1/3] 正在执行 flutter $($BuildArgs -join ' ') ..." -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        & flutter @BuildArgs
        if ($LASTEXITCODE -ne 0) {
            throw "flutter $($BuildArgs -join ' ') 构建失败 (退出码: $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "[1/3] 已跳过编译 (-SkipBuild)，直接使用现有 Release APK 产物..." -ForegroundColor Yellow
}

$FlutterApkDir = Join-Path $RepoRoot 'build\app\outputs\flutter-apk'
$FallbackApkDir = Join-Path $RepoRoot 'build\app\outputs\apk\release'
if (-not (Test-Path -LiteralPath $FlutterApkDir -PathType Container) -and
    -not (Test-Path -LiteralPath $FallbackApkDir -PathType Container)) {
    throw "未找到 Android Release APK 构建目录: $FlutterApkDir 或 $FallbackApkDir"
}

$OutputRoot = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Join-Path $RepoRoot 'dist'
}
else {
    $OutputDir
}
if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

function Resolve-ApkSource {
    param([string]$FileName)
    $primary = Join-Path $FlutterApkDir $FileName
    if (Test-Path -LiteralPath $primary -PathType Leaf) {
        return $primary
    }
    $fallback = Join-Path $FallbackApkDir $FileName
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
        return $fallback
    }
    return $null
}

$Targets = @()
if ($Universal) {
    $Targets += @{
        SourceName = 'app-release.apk'
        DestName   = "MeetSync-v$Version-android-universal.apk"
        Abi        = 'universal'
        Required   = $true
    }
}
else {
    $Targets += @{
        SourceName = 'app-arm64-v8a-release.apk'
        DestName   = "MeetSync-v$Version-android-arm64-v8a.apk"
        Abi        = 'arm64-v8a'
        Required   = $true
    }
    if (-not $Arm64Only) {
        $Targets += @{
            SourceName = 'app-armeabi-v7a-release.apk'
            DestName   = "MeetSync-v$Version-android-armeabi-v7a.apk"
            Abi        = 'armeabi-v7a'
            Required   = $false
        }
        $Targets += @{
            SourceName = 'app-x86_64-release.apk'
            DestName   = "MeetSync-v$Version-android-x86_64.apk"
            Abi        = 'x86_64'
            Required   = $false
        }
    }
}

Write-Host "[2/3] 正在将发布版 APK 整理并输出到: $OutputRoot" -ForegroundColor Cyan
$CopiedEntries = @()
foreach ($target in $Targets) {
    $srcPath = Resolve-ApkSource -FileName $target.SourceName
    if (-not $srcPath) {
        if ($target.Required) {
            throw "未找到必需的 Release APK 文件: $($target.SourceName)（请先不带 -SkipBuild 重新构建）"
        }
        Write-Host "  - 跳过未生成的架构包: $($target.SourceName)" -ForegroundColor DarkGray
        continue
    }

    $destPath = Join-Path $OutputRoot $target.DestName
    Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
    $CopiedEntries += @{
        Abi      = $target.Abi
        DestPath = $destPath
        DestName = $target.DestName
        Source   = $srcPath
    }
}

if ($CopiedEntries.Count -eq 0) {
    throw "未找到任何可复制的 Release APK 文件。"
}

Write-Host "[3/3] 正在校验输出 APK 完整性并计算校验和..." -ForegroundColor Cyan
$SummaryRows = @()
foreach ($entry in $CopiedEntries) {
    if (-not (Test-Path -LiteralPath $entry.DestPath -PathType Leaf)) {
        throw "输出 APK 校验失败，文件不存在: $($entry.DestPath)"
    }
    $fileInfo = Get-Item -LiteralPath $entry.DestPath
    if ($fileInfo.Length -le 0) {
        throw "输出 APK 校验失败，文件为空: $($entry.DestPath)"
    }
    $sha256 = (Get-FileHash -LiteralPath $entry.DestPath -Algorithm SHA256).Hash
    $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
    $SummaryRows += [PSCustomObject]@{
        ABI      = $entry.Abi
        FileName = $entry.DestName
        SizeMB   = "$sizeMB MB"
        SHA256   = $sha256
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Android 发布版 APK 已就绪！" -ForegroundColor Green
Write-Host "输出目录 : $OutputRoot"
Write-Host "版本     : v$Version"
$SummaryRows | Format-Table -AutoSize | Out-String -Width 4096 | ForEach-Object { $_.TrimEnd() } | Write-Host
Write-Host "========================================" -ForegroundColor Green
