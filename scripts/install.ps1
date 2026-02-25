# install.ps1 — SeaBlock 模组包一键安装脚本（Windows PowerShell 5.1+）
# 用法：.\scripts\install.ps1 [-ModsDir <路径>] [-DryRun]
[CmdletBinding()]
param(
    [string]$ModsDir = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModsLock = Join-Path $RepoRoot "mods.lock"
$ExtraModsDir = Join-Path $RepoRoot "extra-mods"
$CacheDir = Join-Path $RepoRoot "download-cache"

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
$DownloadedCache = @{}   # cache_key -> inner_dir

function Invoke-DownloadAndExtract {
    param([string]$CacheKey, [string]$GithubUrl, [string]$Sha)

    if ($DownloadedCache.ContainsKey($CacheKey)) { return }

    $repoPath = $GithubUrl -replace "https://github.com/", "" -replace "\.git$", ""
    $sha8 = $Sha.Substring(0, 8)

    $zipFile    = Join-Path $CacheDir "$CacheKey.zip"
    $zipTmp     = Join-Path $CacheDir "$CacheKey.zip.tmp"
    $extractDir = Join-Path $CacheDir $CacheKey
    $downloadUrl = "https://github.com/$repoPath/archive/$Sha.zip"

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

        # 清理上次中断留下的 .tmp 残留
        if (Test-Path $zipTmp) { Remove-Item $zipTmp -Force }

        if (Test-Path $zipFile) {
            Write-Info "已缓存，跳过下载：$CacheKey"
        } else {
            Write-Info "下载 $CacheKey（$sha8）..."
            $retries = 3
            $success = $false
            for ($i = 1; $i -le $retries; $i++) {
                try {
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipTmp -UseBasicParsing
                    Rename-Item -Path $zipTmp -NewName (Split-Path $zipFile -Leaf)
                    $success = $true
                    break
                } catch {
                    Write-Warn "下载失败，$i/$retries：$_"
                    if (Test-Path $zipTmp) { Remove-Item $zipTmp -Force }
                    if ($i -lt $retries) { Start-Sleep -Seconds 5 }
                }
            }
            if (-not $success) {
                Write-Err "下载 $CacheKey 失败，请检查网络连接后重新运行脚本。"
                exit 1
            }
        }

        if (-not (Test-Path $extractDir -PathType Container)) {
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            # PS 5.1 兼容：Shell.Application 解压（避免 Expand-Archive 长路径限制）
            # CopyHere 是异步的，需要轮询等待解压完成
            $shell = New-Object -ComObject Shell.Application
            $zipObj = $shell.NameSpace($zipFile)
            $itemCount = $zipObj.Items().Count
            $destObj = $shell.NameSpace($extractDir)
            $destObj.CopyHere($zipObj.Items(), 0x14)
            $deadline = (Get-Date).AddMinutes(10)
            while ((Get-ChildItem -Path $extractDir -Recurse -File).Count -lt $itemCount) {
                if ((Get-Date) -gt $deadline) {
                    Write-Err "解压超时：$CacheKey"
                    exit 1
                }
                Start-Sleep -Milliseconds 500
            }
        } else {
            Write-Info "已解压，跳过：$CacheKey"
        }

        $innerDir = (Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1 -ExpandProperty FullName)
        $DownloadedCache[$CacheKey] = $innerDir
    } else {
        Write-Info "下载 $CacheKey（$sha8）..."
        $repoName = Split-Path -Leaf $repoPath
        $DownloadedCache[$CacheKey] = Join-Path $CacheDir "$CacheKey\$repoName-$Sha"
    }
}

# ── 安装一个 mod 目录到 MODS_DIR ─────────────────────────────────────────────
function Install-ModDir {
    param([string]$SrcDir, [string]$ModName)

    if ($DryRun) {
        Write-Info "[DRY-RUN] 将安装 $ModName"
        return
    }

    if (-not (Test-Path $SrcDir -PathType Container)) {
        Write-Err "来源目录不存在：$SrcDir"
        return
    }

    $infoPath = Join-Path $SrcDir "info.json"
    $version = (Get-Content $infoPath -Raw | ConvertFrom-Json).version
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
    $modNames = ($mods | Get-Member -MemberType NoteProperty).Name

    # 按 cache_key 去重，下载各仓库
    $seen = @{}
    foreach ($modName in $modNames) {
        $mod = $mods.$modName
        $key = $mod.cache_key
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            Invoke-DownloadAndExtract -CacheKey $key -GithubUrl $mod.url -Sha $mod.pinned_sha
        }
    }

    # 安装每个 mod
    foreach ($modName in $modNames) {
        $mod = $mods.$modName
        $cacheKey = $mod.cache_key
        $innerDir = $DownloadedCache[$cacheKey]

        # 根据 subdir 字段确定 mod 目录，为 null 时用仓库根目录
        $subdir = $mod.subdir
        if ($subdir -and $subdir -ne "") {
            $modSrcDir = Join-Path $innerDir $subdir
        } else {
            $modSrcDir = $innerDir
        }

        Install-ModDir -SrcDir $modSrcDir -ModName $modName
    }
}

# ── 安装 extra-mods/ 中的附加 mod zip ────────────────────────────────────────
function Install-ExtraMods {
    if (-not (Test-Path $ExtraModsDir -PathType Container)) { return }

    $zipFiles = @(Get-ChildItem -Path $ExtraModsDir -Filter "*.zip")
    if ($zipFiles.Count -eq 0) {
        Write-Info "extra-mods\ 目录为空，跳过附加 mod 安装。"
        return
    }

    Write-Info "=== 安装附加 mod ==="
    foreach ($zip in $zipFiles) {
        $zipBaseName = $zip.Name
        $modName = ($zipBaseName -split "_")[0]

        if ($DryRun) {
            Write-Info "[DRY-RUN] 将安装附加 mod：$zipBaseName"
            continue
        }

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
        Write-Info "[DRY-RUN] 将安装 $destName"
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
    # 复制根目录下的 Lua 脚本（data.lua、data-updates.lua 等）
    Get-ChildItem -Path $RepoRoot -Filter "*.lua" -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $destDir
    }
    Write-Info "已安装：$destName"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
$script:ResolvedModsDir = Get-ModsDir

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
} catch {
    Write-Err "安装失败：$_"
    exit 1
}
