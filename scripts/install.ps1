# install.ps1 — SeaBlock 模组包一键安装脚本（Windows PowerShell）
# 用法：pwsh -File scripts\install.ps1 [-ModsDir <路径>] [-DryRun]
# 要求：PowerShell 5.1+ 或 PowerShell 7+
[CmdletBinding()]
param(
    [string]$ModsDir = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModsLock = Join-Path $RepoRoot "mods.lock"
$ExtraModsDir = Join-Path $RepoRoot "extra-mods"

# ── 颜色输出 ─────────────────────────────────────────────────────────────────
function Write-Info  { param($Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Green }
function Write-Warn  { param($Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

# ── 检测 Factorio mods 目录 ───────────────────────────────────────────────────
function Get-ModsDir {
    if ($ModsDir -ne "") { return $ModsDir }

    $candidates = @(
        Join-Path $env:APPDATA "Factorio\mods"
        Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Factorio\mods"
    )

    foreach ($dir in $candidates) {
        if (Test-Path $dir -PathType Container) { return $dir }
    }

    Write-Err "未找到 Factorio mods 目录。请通过 -ModsDir 手动指定。"
    Write-Err "候选路径：$($candidates -join ', ')"
    exit 1
}

# ── 下载 GitHub archive zip 并解压 ───────────────────────────────────────────
# 返回：解压后的内部根目录路径
$DownloadedCache = @{}   # cache_key -> inner_dir

function Invoke-DownloadAndExtract {
    param([string]$CacheKey, [string]$GithubUrl, [string]$Sha)

    if ($DownloadedCache.ContainsKey($CacheKey)) { return }

    $repoPath = $GithubUrl -replace "https://github.com/", "" -replace "\.git$", ""
    $repoName = Split-Path -Leaf $repoPath
    $sha8 = $Sha.Substring(0, 8)

    $zipFile = Join-Path $TmpDir "$CacheKey.zip"
    $extractDir = Join-Path $TmpDir $CacheKey
    $downloadUrl = "https://github.com/$repoPath/archive/$Sha.zip"

    Write-Info "下载 $CacheKey（$sha8）..."

    if (-not $DryRun) {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UseBasicParsing
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
        Remove-Item $zipFile

        $innerDir = (Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1).FullName
        $DownloadedCache[$CacheKey] = $innerDir
    } else {
        $DownloadedCache[$CacheKey] = Join-Path $extractDir "$repoName-$Sha"
    }
}

# ── 安装一个 mod 目录到 MODS_DIR ─────────────────────────────────────────────
function Install-ModDir {
    param([string]$SrcDir, [string]$ModName)

    if ($DryRun) {
        Write-Info "[DRY-RUN] 将安装 $ModName → $script:ResolvedModsDir\"
        return
    }

    if (-not (Test-Path $SrcDir -PathType Container)) {
        Write-Err "来源目录不存在：$SrcDir"
        return
    }

    $infoJson = Join-Path $SrcDir "info.json"
    $version = (Get-Content $infoJson -Raw | ConvertFrom-Json).version
    $destName = "${ModName}_${version}"
    $destDir = Join-Path $script:ResolvedModsDir $destName

    # 删除同名旧版本
    Get-ChildItem -Path $script:ResolvedModsDir -Directory -Filter "${ModName}_*" | ForEach-Object {
        Write-Warn "已删除旧版本：$($_.Name)"
        Remove-Item $_.FullName -Recurse -Force
    }

    Copy-Item -Path $SrcDir -Destination $destDir -Recurse
    Write-Info "已安装：$destName"
}

# ── 处理 mods.lock 中的所有 mod ──────────────────────────────────────────────
function Install-ModsLock {
    Write-Info "=== 安装 mods.lock 中的 mod ==="

    $lock = Get-Content $ModsLock -Raw | ConvertFrom-Json
    $mods = $lock.mods

    # 按 cache_key 去重，下载各仓库
    $seen = @{}
    foreach ($modName in ($mods | Get-Member -MemberType NoteProperty).Name) {
        $mod = $mods.$modName
        $key = $mod.cache_key
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            Invoke-DownloadAndExtract -CacheKey $key -GithubUrl $mod.url -Sha $mod.pinned_sha
        }
    }

    # 安装每个 mod
    foreach ($modName in ($mods | Get-Member -MemberType NoteProperty).Name) {
        $mod = $mods.$modName
        $cacheKey = $mod.cache_key
        $innerDir = $DownloadedCache[$cacheKey]

        # 判断子目录：locale_files[0].upstream 的第一个路径段
        $firstSeg = $mod.locale_files[0].upstream.Split("/")[0]

        if ($firstSeg -eq "locale") {
            # 仓库根目录就是 mod
            $modSrcDir = $innerDir
        } else {
            # 子目录
            $modSrcDir = Join-Path $innerDir $firstSeg
        }

        Install-ModDir -SrcDir $modSrcDir -ModName $modName
    }
}

# ── 安装 extra-mods/ 中的附加 mod zip ────────────────────────────────────────
function Install-ExtraMods {
    if (-not (Test-Path $ExtraModsDir -PathType Container)) { return }

    $zipFiles = Get-ChildItem -Path $ExtraModsDir -Filter "*.zip"
    if ($zipFiles.Count -eq 0) {
        Write-Info "extra-mods\ 目录为空，跳过附加 mod 安装。"
        return
    }

    Write-Info "=== 安装附加 mod ==="
    foreach ($zip in $zipFiles) {
        $zipBaseName = $zip.Name
        # 文件名格式：<modname>_<version>.zip，取第一个 _ 之前的部分作为 mod 名
        $modName = $zipBaseName -replace "_.*", ""

        if ($DryRun) {
            Write-Info "[DRY-RUN] 将安装附加 mod：$zipBaseName"
            continue
        }

        # 删除旧版本（zip 和目录形式）
        Get-ChildItem -Path $script:ResolvedModsDir -Filter "${modName}_*" | ForEach-Object {
            Write-Warn "已删除旧版本：$($_.Name)"
            Remove-Item $_.FullName -Recurse -Force
        }

        Copy-Item -Path $zip.FullName -Destination (Join-Path $script:ResolvedModsDir $zipBaseName)
        Write-Info "已安装：$zipBaseName"
    }
}

# ── 安装 seablock-translate 本身 ──────────────────────────────────────────────
function Install-Self {
    Write-Info "=== 安装 seablock-translate 翻译 mod ==="

    $selfInfo = Get-Content (Join-Path $RepoRoot "info.json") -Raw | ConvertFrom-Json
    $version = $selfInfo.version
    $destName = "seablock-translate_$version"
    $destDir = Join-Path $script:ResolvedModsDir $destName

    if ($DryRun) {
        Write-Info "[DRY-RUN] 将安装 $destName → $script:ResolvedModsDir\"
        return
    }

    # 删除旧版本
    Get-ChildItem -Path $script:ResolvedModsDir -Directory -Filter "seablock-translate_*" | ForEach-Object {
        Write-Warn "已删除旧版本：$($_.Name)"
        Remove-Item $_.FullName -Recurse -Force
    }

    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot "info.json") -Destination $destDir
    Copy-Item -Path (Join-Path $RepoRoot "locale") -Destination $destDir -Recurse
    Write-Info "已安装：$destName"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
$script:ResolvedModsDir = Get-ModsDir

# 创建临时目录（函数退出时清理）
$TmpDir = Join-Path ([IO.Path]::GetTempPath()) "seablock-install-$(Get-Random)"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {
    Write-Host ""
    Write-Host "=============================="
    Write-Host " SeaBlock 模组包安装脚本"
    Write-Host "=============================="
    Write-Host "  mods 目录：$script:ResolvedModsDir"
    if ($DryRun) { Write-Host "  模式：DRY-RUN（不实际写入）" -ForegroundColor Yellow }
    Write-Host ""

    Install-ModsLock
    Write-Host ""
    Install-ExtraMods
    Write-Host ""
    Install-Self

    Write-Host ""
    Write-Info "安装完成！请启动 Factorio 并在模组管理器中确认所有 mod 已启用。"
} finally {
    Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
