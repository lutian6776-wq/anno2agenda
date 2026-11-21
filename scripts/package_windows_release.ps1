param(
    [switch]$SkipBuild,
    [switch]$Zip,
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
    Write-Host "[1/4] 正在执行 flutter build windows --release ..." -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build windows --release 构建失败 (退出码: $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "[1/4] 已跳过编译 (-SkipBuild)，直接使用现有 Release 构建产物..." -ForegroundColor Yellow
}

$ReleaseDir = Join-Path $RepoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
    throw "未找到 Windows Release 构建目录: $ReleaseDir"
}

$OutputRoot = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Join-Path $RepoRoot 'dist'
}
else {
    $OutputDir
}

$PackageName = "MeetSync-v$Version-windows-x64"
$StageDir = Join-Path $OutputRoot $PackageName

Write-Host "[2/4] 正在按白名单整理纯净发布目录: $StageDir" -ForegroundColor Cyan
if (Test-Path -LiteralPath $StageDir) {
    Remove-Item -LiteralPath $StageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

# 1. 主程序 exe
$ExePath = Join-Path $ReleaseDir 'anno2agenda.exe'
if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    throw "缺少主程序文件: $ExePath"
}
Copy-Item -LiteralPath $ExePath -Destination $StageDir -Force

# 2. 顶层动态库 (*.dll)
Get-ChildItem -LiteralPath $ReleaseDir -Filter '*.dll' -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $StageDir -Force
}

# 3. native_assets.json（若存在）
$NativeAssetsPath = Join-Path $ReleaseDir 'native_assets.json'
if (Test-Path -LiteralPath $NativeAssetsPath -PathType Leaf) {
    Copy-Item -LiteralPath $NativeAssetsPath -Destination $StageDir -Force
}

# 4. data 目录
$DataSrc = Join-Path $ReleaseDir 'data'
if (-not (Test-Path -LiteralPath $DataSrc -PathType Container)) {
    throw "缺少 Flutter 资源目录: $DataSrc（请先不带 -SkipBuild 重新构建）"
}
Copy-Item -LiteralPath $DataSrc -Destination $StageDir -Recurse -Force

# 5. runtime 目录（过滤任何意外残留的模型或压缩包）
$RuntimeSrc = Join-Path $ReleaseDir 'runtime'
if (-not (Test-Path -LiteralPath $RuntimeSrc -PathType Container)) {
    throw "缺少推理运行时目录: $RuntimeSrc"
}
$RuntimeDest = Join-Path $StageDir 'runtime'
New-Item -ItemType Directory -Path $RuntimeDest -Force | Out-Null
$RuntimeSrcPrefix = $RuntimeSrc.TrimEnd('\') + '\'
$ExcludedRuntimeExts = @('.gguf', '.zip', '.7z', '.part')
Get-ChildItem -LiteralPath $RuntimeSrc -Recurse -File | ForEach-Object {
    $ext = $_.Extension.ToLowerInvariant()
    if ($ExcludedRuntimeExts -contains $ext) {
        return
    }
    $relPath = $_.FullName.Substring($RuntimeSrcPrefix.Length)
    $destFile = Join-Path $RuntimeDest $relPath
    $destParent = Split-Path -Path $destFile -Parent
    if (-not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $destFile -Force
}

Write-Host "[3/4] 正在校验发布目录完整性与纯净度..." -ForegroundColor Cyan
$RequiredRelativePaths = @(
    'anno2agenda.exe',
    'flutter_windows.dll',
    'data\app.so',
    'data\icudtl.dat',
    'data\flutter_assets',
    'runtime\llama-server.exe'
)
foreach ($rel in $RequiredRelativePaths) {
    $checkPath = Join-Path $StageDir $rel
    if (-not (Test-Path -LiteralPath $checkPath)) {
        throw "发布目录完整性校验失败，缺少必需文件/目录: $checkPath"
    }
}

$GgufHits = @(Get-ChildItem -LiteralPath $StageDir -Recurse -File -Filter '*.gguf' -ErrorAction SilentlyContinue)
if ($GgufHits.Count -gt 0) {
    throw "发布目录校验失败：检测到模型权重文件残留 ($($GgufHits[0].FullName))"
}

$ModelsDirHits = @(Get-ChildItem -LiteralPath $StageDir -Recurse -Directory -Filter 'models' -ErrorAction SilentlyContinue)
if ($ModelsDirHits.Count -gt 0) {
    throw "发布目录校验失败：检测到 models 目录残留 ($($ModelsDirHits[0].FullName))"
}

$ForbiddenFiles = @('app_settings.json', 'agenda_events.json', 'theme_mode.txt', 'custom_system_prompt.txt')
$ForbiddenHits = @(Get-ChildItem -LiteralPath $StageDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $ForbiddenFiles -contains $_.Name })
if ($ForbiddenHits.Count -gt 0) {
    throw "发布目录校验失败：检测到本地测试配置文件残留 ($($ForbiddenHits[0].FullName))"
}

$ZipPath = $null
if ($Zip) {
    Write-Host "[4/4] 正在生成压缩包..." -ForegroundColor Cyan
    $ZipPath = Join-Path $OutputRoot "$PackageName.zip"
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    Compress-Archive -Path $StageDir -DestinationPath $ZipPath -Force
}
else {
    Write-Host "[4/4] 已跳过压缩（如需生成 .zip 请附加 -Zip 参数）" -ForegroundColor DarkGray
}

$Stats = Get-ChildItem -LiteralPath $StageDir -Recurse -File | Measure-Object -Property Length -Sum
$TotalMB = [math]::Round($Stats.Sum / 1MB, 2)

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "纯净发布包已就绪！" -ForegroundColor Green
Write-Host "发布目录 : $StageDir"
if ($ZipPath) {
    $ZipMB = [math]::Round((Get-Item -LiteralPath $ZipPath).Length / 1MB, 2)
    Write-Host "压缩包   : $ZipPath ($ZipMB MB)"
}
Write-Host "文件统计 : $($Stats.Count) 个文件，总大小 $TotalMB MB"
Write-Host "纯净检查 : 已排除 models\、*.gguf 及本地测试配置；原开发/测试 models 目录保持原样未改动。"
Write-Host "========================================" -ForegroundColor Green
