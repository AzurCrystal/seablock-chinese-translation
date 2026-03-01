# populate-locale.ps1 — 从 bare clone 提取英文原文，初始化 zh-CN 翻译文件
#
# 用法: .\scripts\windows\populate-locale.ps1 [mod-name ...] [-Force]
#   无参数：处理所有 upstream_only=false 且尚无 zh-CN 文件的 locale 文件
#   有参数：只处理指定 mod
#
# 前提: 先运行 init-cache.ps1 建立 upstream-cache\
#
# 说明:
#   - 已存在的 zh-CN 文件不会被覆盖（用 -Force 强制覆盖）
#   - 提取的是 pinned_sha 版本的英文原文，作为翻译起点
#
# 依赖: git（PATH 中可用）

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Mods = @(),

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$RepoRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LockFile  = Join-Path $RepoRoot "mods.lock"
$CacheDir  = Join-Path $RepoRoot "upstream-cache"
$LocaleDir = Join-Path $RepoRoot "locale\zh-CN"

if (-not (Test-Path $LockFile)) {
    Write-Host "ERROR: mods.lock not found at $LockFile" -ForegroundColor Red
    exit 1
}

$lock = Get-Content $LockFile -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $LocaleDir -Force | Out-Null

$okCount   = 0
$skipCount = 0
$failCount = 0

function Get-GitShowWithRetry {
    param([string]$GitDir, [string]$Sha, [string]$Path)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $content = & git --git-dir=$GitDir show "${Sha}:${Path}" 2>&1
        if ($LASTEXITCODE -eq 0) { return ($content -join "`n") }
        if ($attempt -lt 3) { Start-Sleep -Seconds 1 }
    }
    return $null
}

foreach ($entry in $lock.mods.PSObject.Properties) {
    $modName      = $entry.Name
    $modData      = $entry.Value
    $upstreamOnly = $modData.upstream_only
    $cacheKey     = if ($modData.cache_key) { $modData.cache_key } else { $modName }
    $pinned       = $modData.pinned_sha

    # 过滤：若指定了 mod 列表，只处理匹配项
    if ($Mods.Count -gt 0 -and $modName -notin $Mods) { continue }

    # 跳过 upstream_only mod
    if ($upstreamOnly -eq $true) {
        Write-Host "[SKIP]  $modName — upstream_only" -ForegroundColor DarkGray
        continue
    }

    $localeFiles = $modData.locale_files
    if ($null -eq $localeFiles -or $localeFiles.Count -eq 0) { continue }

    $bare = Join-Path $CacheDir "$cacheKey.git"
    if (-not (Test-Path $bare -PathType Container)) {
        Write-Host "[ERROR] $modName — bare clone missing: $bare" -ForegroundColor Red
        Write-Host "        Run .\scripts\windows\init-cache.ps1 first." -ForegroundColor Red
        $failCount++
        continue
    }

    foreach ($lf in $localeFiles) {
        $upstreamPath = $lf.upstream
        $localName    = $lf.local
        $dest         = Join-Path $LocaleDir $localName

        if ((Test-Path $dest) -and -not $Force) {
            Write-Host "[SKIP]  $localName — already exists" -ForegroundColor DarkGray
            $skipCount++
            continue
        }

        Write-Host "[FETCH] $modName  $upstreamPath → zh-CN/$localName ... " -NoNewline

        $content = Get-GitShowWithRetry $bare $pinned $upstreamPath
        if ($null -eq $content) {
            Write-Host "FAIL" -ForegroundColor Red
            Write-Host "        ERROR: git show failed for $upstreamPath at $($pinned.Substring(0,8))" -ForegroundColor Red
            $failCount++
            continue
        }

        $enc = [System.Text.UTF8Encoding]::new($false)
        # 确保文件末尾有换行
        $text = if ($content.EndsWith("`n")) { $content } else { $content + "`n" }
        [System.IO.File]::WriteAllText($dest, $text, $enc)

        Write-Host "OK" -ForegroundColor Green
        $okCount++
    }
}

Write-Host ""
Write-Host ("─" * 60)
Write-Host "Done.  created: $okCount  skipped: $skipCount  failed: $failCount"
Write-Host "Output: $LocaleDir"

if ($failCount -gt 0) { exit 1 }
