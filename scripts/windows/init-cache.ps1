# init-cache.ps1 — 初始化所有 mods.lock 中的上游 bare clone 缓存
#
# 用法: .\scripts\windows\init-cache.ps1
#   读取 mods.lock，对每个唯一仓库在 upstream-cache\ 下建立 bare clone。
#   已存在的缓存直接跳过；只拉取 pinned_sha，不下载多余对象。
#
# 完成后即可使用 diff-upstream.ps1 等脚本而无需联网初始化。
#
# 依赖: git（PATH 中可用）

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LockFile = Join-Path $RepoRoot "mods.lock"
$CacheDir = Join-Path $RepoRoot "upstream-cache"

if (-not (Test-Path $LockFile)) {
    Write-Host "ERROR: mods.lock not found at $LockFile" -ForegroundColor Red
    exit 1
}

$lock = Get-Content $LockFile -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

$seenKeys  = @{}
$okCount   = 0
$skipCount = 0
$failCount = 0

foreach ($entry in $lock.mods.PSObject.Properties) {
    $modName  = $entry.Name
    $modData  = $entry.Value
    $url      = $modData.url
    $branch   = $modData.upstream_branch
    $pinned   = $modData.pinned_sha
    $cacheKey = if ($modData.cache_key) { $modData.cache_key } else { $modName }

    # 已处理过该 cache_key 则跳过
    if ($seenKeys.ContainsKey($cacheKey)) { continue }
    $seenKeys[$cacheKey] = $true

    $bare = Join-Path $CacheDir "$cacheKey.git"

    if (Test-Path $bare -PathType Container) {
        Write-Host "[SKIP]  $cacheKey — $bare" -ForegroundColor DarkGray
        $skipCount++
        continue
    }

    Write-Host "[CLONE] $cacheKey" -ForegroundColor Cyan
    Write-Host "        $url  (branch: $branch)"

    & git clone --bare --filter=blob:none --no-tags --branch $branch $url $bare 2>&1 |
        ForEach-Object { Write-Host "        $_" }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL]  $cacheKey — git clone failed" -ForegroundColor Red
        if (Test-Path $bare) { Remove-Item $bare -Recurse -Force }
        $failCount++
        Write-Host ""
        continue
    }

    # 确保 pinned SHA 可达（shallow clone 可能缺旧提交）
    & git --git-dir=$bare cat-file -e "$pinned^{commit}" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "        Fetching pinned $($pinned.Substring(0,8)) ..."
        & git --git-dir=$bare fetch --filter=blob:none --no-tags origin $pinned 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git --git-dir=$bare fetch --filter=blob:none --no-tags origin 2>&1 | Out-Null
        }
    }

    Write-Host "[OK]    $cacheKey  (pinned: $($pinned.Substring(0,8)))" -ForegroundColor Green
    $okCount++
    Write-Host ""
}

Write-Host ("─" * 60)
Write-Host "Done.  cloned: $okCount  skipped: $skipCount  failed: $failCount"
Write-Host "Cache: $CacheDir"

if ($failCount -gt 0) { exit 1 }
