# check-updates.ps1 — 零带宽检测上游 locale 是否有新 commit
#
# 用法: .\scripts\ps1\check-updates.ps1 [mod-name ...]
#   不带参数: 检查 mods.lock 中所有 mod
#   带参数:   只检查指定的 mod
#
# 依赖: git
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Mods = @()
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LockFile = Join-Path $RepoRoot "mods.lock"

if (-not (Test-Path $LockFile)) {
    Write-Host "ERROR: mods.lock not found at $LockFile" -ForegroundColor Red
    exit 1
}

$lock = Get-Content $LockFile -Raw | ConvertFrom-Json

if ($Mods.Count -eq 0) {
    $Mods = ($lock.mods | Get-Member -MemberType NoteProperty).Name
}

# 缓存 "url::branch" -> tip SHA（避免对同一远端重复发起请求）
$tipCache = @{}

$okCount      = 0
$changedCount = 0
$errorCount   = 0

foreach ($mod in $Mods) {
    $modData = $lock.mods.$mod
    if ($null -eq $modData) {
        Write-Host "[ERROR]   $mod — not found in mods.lock" -ForegroundColor Red
        $errorCount++
        continue
    }

    $url          = $modData.url
    $branch       = $modData.upstream_branch
    $pinned       = $modData.pinned_sha
    $upstreamOnly = $modData.upstream_only

    $cacheKey = "${url}::${branch}"
    if (-not $tipCache.ContainsKey($cacheKey)) {
        $raw = & git ls-remote $url "refs/heads/$branch" 2>&1
        $current = if ($LASTEXITCODE -eq 0 -and $raw) {
            ($raw | Select-Object -First 1) -split "\s+" | Select-Object -First 1
        } else { "ERROR" }
        $tipCache[$cacheKey] = $current
    }
    $current = $tipCache[$cacheKey]

    if ($current -eq "ERROR") {
        Write-Host ("[ERROR]   {0,-40} — failed to reach remote" -f $mod) -ForegroundColor Red
        $errorCount++
    } elseif ($current -eq $pinned) {
        if ($upstreamOnly -eq $true) {
            Write-Host ("[OK/auto] {0,-40} @ {1}  (upstream-only)" -f $mod, $pinned.Substring(0, 8))
        } else {
            Write-Host ("[OK]      {0,-40} @ {1}" -f $mod, $pinned.Substring(0, 8))
        }
        $okCount++
    } else {
        if ($upstreamOnly -eq $true) {
            Write-Host ("[CHANGED] {0,-40}  pinned={1,-8}  upstream={2,-8}  (upstream-only, safe to auto-upgrade)" -f $mod, $pinned.Substring(0, 8), $current.Substring(0, 8))
        } else {
            Write-Host ("[CHANGED] {0,-40}  pinned={1,-8}  upstream={2,-8}" -f $mod, $pinned.Substring(0, 8), $current.Substring(0, 8))
        }
        $changedCount++
    }
}

Write-Host ""
Write-Host "Summary: $okCount up-to-date, $changedCount changed, $errorCount errors"

if ($changedCount -gt 0) {
    Write-Host ""
    Write-Host "To inspect changes for a mod:"
    Write-Host "  .\scripts\windows\diff-upstream.ps1 <mod-name> <new-sha>"
    Write-Host ""
    Write-Host "To update the pin after reviewing:"
    Write-Host "  .\scripts\windows\update-pin.ps1 <mod-name> <new-sha>"
}
