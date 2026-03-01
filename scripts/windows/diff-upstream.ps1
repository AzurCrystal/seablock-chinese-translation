# diff-upstream.ps1 — 按需拉取上游 locale 文件，比较两版本差异后丢弃
#
# 用法: .\scripts\ps1\diff-upstream.ps1 <mod-name> [new-sha]
#   <mod-name>: mods.lock 中的 mod 名称
#   [new-sha]:  上游新的 commit SHA（完整或前缀均可）；省略时自动取上游 branch tip
#
# 输出: 每个 locale 文件从 pinned_sha 到 new-sha 的 unified diff
# 不在磁盘写入任何英文 locale 文件。
#
# 依赖: git
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
$CacheDir = Join-Path $RepoRoot "upstream-cache"

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

$url    = $modData.url
$branch = $modData.upstream_branch

if ($NewSha -eq "") {
    Write-Host "Fetching upstream tip for $ModName ($branch) ..." -ForegroundColor Cyan
    $raw = & git ls-remote $url "refs/heads/$branch" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        Write-Host "ERROR: failed to reach upstream ($url)" -ForegroundColor Red
        exit 1
    }
    $NewSha = ($raw | Select-Object -First 1) -split "\s+" | Select-Object -First 1
}

$pinned       = $modData.pinned_sha
$cacheKey     = if ($modData.cache_key) { $modData.cache_key } else { $ModName }
$upstreamOnly = $modData.upstream_only

$bare    = Join-Path $CacheDir "$cacheKey.git"
$diffDir = Join-Path $RepoRoot "diffs"
New-Item -ItemType Directory -Path $diffDir -Force | Out-Null
$outFile = Join-Path $diffDir "$ModName-$($pinned.Substring(0,8))-$($NewSha.Substring(0,8)).diff"

# 收集输出行，最后写入 diff 文件
$lines = [System.Collections.Generic.List[string]]::new()
function Out-Line {
    param([string]$Text = "")
    Write-Host $Text
    $script:lines.Add($Text)
}

if ($upstreamOnly -eq $true) {
    Out-Line "Note: '$ModName' is marked upstream_only — upstream translations are used as-is."
    Out-Line ""
}

Out-Line "Diffing ${ModName}: $($pinned.Substring(0,8)) → $($NewSha.Substring(0,8))"
Out-Line "Upstream: $url ($branch)"
Out-Line ""

# 建立 bare clone（若已存在则跳过）
if (-not (Test-Path $bare -PathType Container)) {
    Write-Host "Cloning bare repo to $bare ..."
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    & git clone --bare --filter=blob:none --no-tags --branch $branch $url $bare
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: git clone failed" -ForegroundColor Red; exit 1 }
}

function Invoke-EnsureSha {
    param([string]$Sha)
    & git --git-dir=$bare cat-file -e "$Sha^{commit}" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Fetching missing commit $($Sha.Substring(0,8)) ..." -ForegroundColor Yellow
        & git --git-dir=$bare fetch --filter=blob:none --no-tags origin $Sha 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Deepening clone to find $($Sha.Substring(0,8)) ..." -ForegroundColor Yellow
            & git --git-dir=$bare fetch --filter=blob:none --no-tags --unshallow origin 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & git --git-dir=$bare fetch --filter=blob:none --no-tags origin 2>&1 | Out-Null
            }
        }
    }
}

function Get-GitShowWithRetry {
    param([string]$GitDir, [string]$Sha, [string]$Path)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $content = & git --git-dir=$GitDir show "${Sha}:${Path}" 2>&1
        if ($LASTEXITCODE -eq 0) { return ($content -join "`n") }
        if ($attempt -lt 3) { Start-Sleep -Seconds 1 }
    }
    return $null
}

# 找 diff 可执行文件（优先 PATH，其次 Git 安装目录）
function Find-DiffExe {
    $d = Get-Command diff -ErrorAction SilentlyContinue
    if ($d) { return $d.Source }
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if ($gitExe) {
        $gitBin = Split-Path $gitExe.Source
        foreach ($rel in @("..\usr\bin\diff.exe", "..\..\usr\bin\diff.exe")) {
            $candidate = Join-Path $gitBin $rel
            if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        }
    }
    return $null
}
$diffExe = Find-DiffExe

function Invoke-FileDiff {
    param([string]$OldContent, [string]$NewContent, [string]$OldLabel, [string]$NewLabel)

    $tmpDir = [System.IO.Path]::GetTempPath()
    $tmpOld = Join-Path $tmpDir "diff_old_$([System.IO.Path]::GetRandomFileName())"
    $tmpNew = Join-Path $tmpDir "diff_new_$([System.IO.Path]::GetRandomFileName())"
    try {
        $enc = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmpOld, $OldContent, $enc)
        [System.IO.File]::WriteAllText($tmpNew, $NewContent, $enc)

        if ($script:diffExe) {
            return & $script:diffExe --unified=5 --label $OldLabel --label $NewLabel $tmpOld $tmpNew
        } else {
            # git diff --no-index 回退（labels 使用路径名，近似效果）
            return & git diff --no-index --unified=5 -- $tmpOld $tmpNew
        }
    } finally {
        Remove-Item $tmpOld, $tmpNew -Force -ErrorAction SilentlyContinue
    }
}

Invoke-EnsureSha $pinned
Invoke-EnsureSha $NewSha

$foundDiff   = $false
$localeFiles = $modData.locale_files

foreach ($lf in $localeFiles) {
    $upstreamPath = $lf.upstream
    $localName    = $lf.local

    Out-Line ("═" * 59)
    Out-Line "  File: $upstreamPath"
    Out-Line "  Maps to: locale/zh-CN/$localName"
    Out-Line ("═" * 59)

    $oldContent = Get-GitShowWithRetry $bare $pinned $upstreamPath
    $newContent = Get-GitShowWithRetry $bare $NewSha $upstreamPath
    $oldExists  = $null -ne $oldContent
    $newExists  = $null -ne $newContent

    if (-not $oldExists -and -not $newExists) {
        Out-Line "(file absent in both commits — skipping)"
    } elseif (-not $oldExists) {
        Out-Line "(file added in $($NewSha.Substring(0,8)))"
        $foundDiff = $true
        $diffOut = Invoke-FileDiff "" $newContent `
            "a/$upstreamPath ($($pinned.Substring(0,8))) [did not exist]" `
            "b/$upstreamPath ($($NewSha.Substring(0,8)))"
        foreach ($l in $diffOut) { Out-Line $l }
    } elseif (-not $newExists) {
        Out-Line "(file deleted in $($NewSha.Substring(0,8)))"
        $foundDiff = $true
        $diffOut = Invoke-FileDiff $oldContent "" `
            "a/$upstreamPath ($($pinned.Substring(0,8)))" `
            "b/$upstreamPath ($($NewSha.Substring(0,8))) [deleted]"
        foreach ($l in $diffOut) { Out-Line $l }
    } elseif ($oldContent -eq $newContent) {
        Out-Line "(no changes)"
    } else {
        $foundDiff = $true
        $diffOut = Invoke-FileDiff $oldContent $newContent `
            "a/$upstreamPath ($($pinned.Substring(0,8)))" `
            "b/$upstreamPath ($($NewSha.Substring(0,8)))"
        foreach ($l in $diffOut) { Out-Line $l }
    }
    Out-Line ""
}

if (-not $foundDiff) {
    Out-Line "No locale file changes between $($pinned.Substring(0,8)) and $($NewSha.Substring(0,8))."
}

Out-Line ("─" * 60)
Out-Line "To update the pin after reviewing:"
Out-Line "  .\scripts\windows\update-pin.ps1 $ModName $NewSha"
Out-Line ""
Out-Line "Diff saved to: $outFile"

[System.IO.File]::WriteAllLines($outFile, $lines, [System.Text.UTF8Encoding]::new($false))
