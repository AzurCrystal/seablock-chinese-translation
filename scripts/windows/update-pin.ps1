# update-pin.ps1 — 更新 mods.lock 中指定 mod 的 pinned_sha
#
# 用法: .\scripts\ps1\update-pin.ps1 <mod-name> [new-sha]
#   <mod-name>: mods.lock 中的 mod 名称
#   [new-sha]:  要锁定到的新 commit SHA（必须是完整 40 位 SHA）；省略时自动取上游 branch tip
#
# 同一 cache_key 下的所有 mod 共享同一个仓库，若检测到相同 cache_key 的其他
# mod 仍在旧 SHA，脚本会提示一并更新。
#
# 依赖: git, jq（若不在 PATH 中则回退到 PS 原生 JSON 处理）
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ModName,
    [Parameter(Position = 1)]
    [string]$NewSha = ""
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LockFile = Join-Path $RepoRoot "mods.lock"

if (-not (Test-Path $LockFile)) {
    Write-Host "ERROR: mods.lock not found at $LockFile" -ForegroundColor Red
    exit 1
}

$lock    = Get-Content $LockFile -Raw | ConvertFrom-Json
$modData = $lock.mods.$ModName
if ($null -eq $modData) {
    Write-Host "ERROR: mod '$ModName' not found in mods.lock" -ForegroundColor Red
    exit 1
}

$url = $modData.url

if ($NewSha -eq "") {
    $branch = $modData.upstream_branch
    Write-Host "Fetching upstream tip for $ModName ($branch) ..."
    $raw = & git ls-remote $url "refs/heads/$branch" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        Write-Host "ERROR: failed to reach upstream ($url)" -ForegroundColor Red
        exit 1
    }
    $NewSha = ($raw | Select-Object -First 1) -split "\s+" | Select-Object -First 1
    Write-Host "  upstream tip: $NewSha"
    Write-Host ""
} else {
    # 验证 SHA 格式（40 位十六进制）
    if ($NewSha -notmatch '^[0-9a-f]{40}$') {
        Write-Host "ERROR: new-sha must be a full 40-character hex SHA (got: '$NewSha')" -ForegroundColor Red
        exit 1
    }
}

$oldSha = $modData.pinned_sha
$today  = (Get-Date -Format "yyyy-MM-dd")

if ($oldSha -eq $NewSha) {
    Write-Host "Already pinned to $NewSha — nothing to do."
    exit 0
}

$cacheKey     = if ($modData.cache_key) { $modData.cache_key } else { $ModName }
$upstreamOnly = $modData.upstream_only

if ($upstreamOnly -eq $true) {
    Write-Host "Note: '$ModName' is marked upstream_only."
    Write-Host "      No local translation file to update — upgrading pin directly."
    Write-Host ""
}

# 找出共享同一 cache_key 且 pinned_sha 不同的 mod（同仓库其他条目）
$siblings = @()
foreach ($entry in ($lock.mods | Get-Member -MemberType NoteProperty)) {
    $name = $entry.Name
    if ($name -eq $ModName) { continue }
    $sibling    = $lock.mods.$name
    $sibCacheKey = if ($sibling.cache_key) { $sibling.cache_key } else { $name }
    if ($sibCacheKey -eq $cacheKey -and $sibling.pinned_sha -ne $NewSha) {
        $siblings += $name
    }
}

$updateSiblings = $false
if ($siblings.Count -gt 0) {
    Write-Host "The following mods share the same upstream repo (cache_key=$cacheKey)"
    Write-Host "and are not yet pinned to $NewSha:"
    foreach ($s in $siblings) {
        $ssha = $lock.mods.$s.pinned_sha
        Write-Host ("  - {0} (currently {1})" -f $s, $ssha.Substring(0, 8))
    }
    Write-Host ""
    Write-Host "It is recommended to update all of them together."
    $answer = Read-Host "Update all of the above as well? [Y/n]"
    if ($answer -eq "" -or $answer -match '^[Yy]$') {
        $updateSiblings = $true
    } else {
        Write-Host "Updating only '$ModName'."
    }
}

# 用 jq 更新（若可用则格式不变），否则用 PS 原生 JSON 处理
$jqExe = Get-Command jq -ErrorAction SilentlyContinue

if ($jqExe) {
    # 与 sh 版本行为完全一致：jq 原地更新，保留原文件格式
    $jqArgs = @("--arg", "new_sha", $NewSha, "--arg", "today", $today, "--arg", "mod", $ModName)
    $jqExpr = '.mods[$mod].pinned_sha = $new_sha | .mods[$mod].pinned_at = $today'

    if ($updateSiblings) {
        $i = 0
        foreach ($s in $siblings) {
            $jqArgs += @("--arg", "sib$i", $s)
            $jqExpr += " | .mods[`$sib$i].pinned_sha = `$new_sha | .mods[`$sib$i].pinned_at = `$today"
            $i++
        }
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & $jqExe.Source @jqArgs $jqExpr $LockFile | Set-Content $tmp -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "jq failed" }
        # 写入无 BOM 的 UTF-8
        $content = Get-Content $tmp -Raw
        [System.IO.File]::WriteAllText($LockFile, $content, [System.Text.UTF8Encoding]::new($false))
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
} else {
    # 回退：PS 原生 JSON（功能等同，首次运行可能重新格式化文件）
    $lock.mods.$ModName.pinned_sha = $NewSha
    $lock.mods.$ModName.pinned_at  = $today
    if ($updateSiblings) {
        foreach ($s in $siblings) {
            $lock.mods.$s.pinned_sha = $NewSha
            $lock.mods.$s.pinned_at  = $today
        }
    }
    $json = $lock | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($LockFile, $json, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "Updated mods.lock:"
Write-Host ("  {0}: {1} → {2}" -f $ModName, $oldSha.Substring(0, 8), $NewSha.Substring(0, 8))
if ($updateSiblings) {
    foreach ($s in $siblings) {
        Write-Host "  ${s}: also updated to $($NewSha.Substring(0, 8))"
    }
}
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Update translations in locale/zh-CN/ if needed"
Write-Host "  2. git add mods.lock locale/zh-CN/"
Write-Host "  3. git commit -m `"chore: upgrade $ModName to $($NewSha.Substring(0, 8))`""
