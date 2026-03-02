# install.ps1 —— SeaBlock 模组一键安装脚本（Windows PowerShell 5.1+）
# 用法：.\scripts\install.ps1 [-Full] [-ModsDir <路径>] [-DryRun]
[CmdletBinding()]
param(
    [string]$ModsDir = "",
    [switch]$DryRun,
    [switch]$Full
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModsLock = Join-Path $RepoRoot "mods.lock"
$ExtraModsDir = Join-Path $RepoRoot "extra-mods"
$CacheDir = Join-Path $RepoRoot "download-cache"

# ─── 颜色输出 ──────────────────────────────────────────────────────────────────
function Write-Info  { param($Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Green }
function Write-Warn  { param($Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

# ─── 查找 Factorio mods 目录 ───────────────────────────────────────────────────
function Get-ModsDir {
    if ($ModsDir -ne "") { return $ModsDir }

    $candidates = @(
        Join-Path $env:APPDATA "Factorio\mods"
        Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Factorio\mods"
    )

    foreach ($dir in $candidates) {
        if (Test-Path $dir -PathType Container) { return $dir }
    }

    Write-Err "未找到 Factorio mods 目录，请通过 -ModsDir 手动指定："
    Write-Err "候选路径：$($candidates -join ', ')"
    exit 1
}

# ─── 下载 GitHub archive zip 并解压 ───────────────────────────────────────────
$DownloadedCache = @{}   # cache_key -> extract dir

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

        # 清除上次中断留下的 .tmp 文件
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
                    Write-Warn "下载失败（$i/$retries）：$_"
                    if (Test-Path $zipTmp) { Remove-Item $zipTmp -Force }
                    if ($i -lt $retries) { Start-Sleep -Seconds 5 }
                }
            }
            if (-not $success) {
                Write-Err "下载 $CacheKey 失败，请检查网络后重新运行脚本。"
                exit 1
            }
        }

        if (-not (Test-Path $extractDir -PathType Container)) {
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            $tarExe = Join-Path $env:SystemRoot "System32\tar.exe"
            if (Test-Path $tarExe) {
                # tar（Windows 10 1803+ 内置）：同步、快速，--strip-components=1 直接跳过顶层目录
                & $tarExe -xf $zipFile --strip-components=1 -C $extractDir
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "解压失败：$CacheKey"
                    exit 1
                }
            } else {
                # 回退：Shell.Application（较慢，CopyHere 异步，需轮询等待）
                $shell = New-Object -ComObject Shell.Application
                $zipObj = $shell.NameSpace($zipFile)
                $topItem = ($zipObj.Items() | Select-Object -First 1)
                $innerNs = $shell.NameSpace($topItem)
                $itemCount = $innerNs.Items().Count
                $destObj = $shell.NameSpace($extractDir)
                $destObj.CopyHere($innerNs.Items(), 0x14)
                $deadline = (Get-Date).AddMinutes(10)
                while ((Get-ChildItem -Path $extractDir -Recurse -File).Count -lt $itemCount) {
                    if ((Get-Date) -gt $deadline) {
                        Write-Err "解压超时：$CacheKey"
                        exit 1
                    }
                    Start-Sleep -Milliseconds 500
                }
            }
        } else {
            Write-Info "已解压，跳过下载：$CacheKey"
        }

        $DownloadedCache[$CacheKey] = $extractDir
    } else {
        Write-Info "下载 $CacheKey（$sha8）..."
        $DownloadedCache[$CacheKey] = Join-Path $CacheDir $CacheKey
    }
}

# ─── 安装一个 mod 目录到 MODS_DIR ─────────────────────────────────────────────
function Install-ModDir {
    param([string]$SrcDir, [string]$ModName)

    if ($DryRun) {
        Write-Info "[DRY-RUN] 将安装 $ModName"
        return
    }

    if (-not (Test-Path $SrcDir -PathType Container)) {
        Write-Err "源目录不存在：$SrcDir"
        return
    }

    $infoPath = Join-Path $SrcDir "info.json"
    $version = (Get-Content $infoPath -Raw | ConvertFrom-Json).version
    $destName = "${ModName}_${version}"
    $destDir = Join-Path $script:ResolvedModsDir $destName

    # 删除同名旧版本
    Get-ChildItem -Path $script:ResolvedModsDir -Directory -Filter "${ModName}_*" | ForEach-Object {
        Write-Warn "正删除旧版本：$($_.Name)"
        Remove-Item $_.FullName -Recurse -Force
    }

    Copy-Item -Path $SrcDir -Destination $destDir -Recurse
    Write-Info "已安装：$destName"
}

# ─── 安装 mods.lock 中的所有 mod ──────────────────────────────────────────────
function Install-ModsLock {
    Write-Info "=== 安装 mods.lock 中的 mod ==="

    $lock = Get-Content $ModsLock -Raw | ConvertFrom-Json
    $mods = $lock.mods
    $modNames = ($mods | Get-Member -MemberType NoteProperty).Name

    # 按 cache_key 去重，避免重复下载
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

        # 根据 subdir 字段确定 mod 目录，为 null 时取仓库根目录
        $subdir = $mod.subdir
        if ($subdir -and $subdir -ne "") {
            $modSrcDir = Join-Path $innerDir $subdir
        } else {
            $modSrcDir = $innerDir
        }

        Install-ModDir -SrcDir $modSrcDir -ModName $modName
    }
}

# ─── 安装 extra-mods/ 中的附带 mod zip ────────────────────────────────────────
function Install-ExtraMods {
    if (-not (Test-Path $ExtraModsDir -PathType Container)) { return }

    $zipFiles = @(Get-ChildItem -Path $ExtraModsDir -Filter "*.zip")
    if ($zipFiles.Count -eq 0) {
        Write-Info "extra-mods\ 目录为空，无附带 mod 安装。"
        return
    }

    Write-Info "=== 安装附带 mod ==="
    foreach ($zip in $zipFiles) {
        $zipBaseName = $zip.Name
        $modName = $zipBaseName -replace '_\d+\.\d+.*$', ''

        if ($DryRun) {
            Write-Info "[DRY-RUN] 将安装附带 mod：$zipBaseName"
            continue
        }

        Get-ChildItem -Path $script:ResolvedModsDir -Filter "${modName}_*" | ForEach-Object {
            Write-Warn "正删除旧版本：$($_.Name)"
            Remove-Item $_.FullName -Recurse -Force
        }

        Copy-Item -Path $zip.FullName -Destination (Join-Path $script:ResolvedModsDir $zipBaseName)
        Write-Info "已安装：$zipBaseName"
    }
}

# ─── 安装 seablock-translate 本身 ─────────────────────────────────────────────
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
        Write-Warn "正删除旧版本：$($_.Name)"
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

# ─── 更新 mod-list.json ────────────────────────────────────────────────────────
function Update-ModList {
    Write-Info "=== 更新 mod-list.json ==="

    $modListPath = Join-Path $script:ResolvedModsDir "mod-list.json"

    # 1. 构建"需要启用"的 mod 名称集合
    $required = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $null = $required.Add("seablock-translate")

    $lock = Get-Content $ModsLock -Raw | ConvertFrom-Json
    foreach ($name in ($lock.mods | Get-Member -MemberType NoteProperty).Name) {
        $null = $required.Add($name)
    }

    if (Test-Path $ExtraModsDir) {
        foreach ($zip in (Get-ChildItem -Path $ExtraModsDir -Filter "*.zip")) {
            $null = $required.Add(($zip.BaseName -replace '_\d+\.\d+.*$', ''))
        }
    }

    # 2. 读取现有 mod-list.json（保留 DLC 等 Factorio 自管理的条目）
    $existingMap = [ordered]@{}
    if (Test-Path $modListPath) {
        foreach ($entry in ((Get-Content $modListPath -Raw | ConvertFrom-Json).mods)) {
            $existingMap[$entry.name] = $entry.enabled
        }
    }

    # 3. 扫描 mods 目录，收集已安装的 mod 名称
    $installed = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($dir in (Get-ChildItem -Path $script:ResolvedModsDir -Directory)) {
        $infoFile = Join-Path $dir.FullName "info.json"
        if (Test-Path $infoFile) {
            try { $n = (Get-Content $infoFile -Raw | ConvertFrom-Json).name; if ($n) { $null = $installed.Add($n) } } catch {}
        }
    }
    foreach ($zip in (Get-ChildItem -Path $script:ResolvedModsDir -Filter "*.zip" -File)) {
        $null = $installed.Add(($zip.BaseName -replace '_\d+\.\d+.*$', ''))
    }

    # 4. 合并所有已知名称（现有条目 + 新扫描到的）
    $allNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $existingMap.Keys) { $null = $allNames.Add($n) }
    foreach ($n in $installed)        { $null = $allNames.Add($n) }

    # 5. 构建最终列表：base 永远启用，其余按 required 集合决定
    $modEntries = $allNames | Sort-Object | ForEach-Object {
        $enable = ($_ -eq "base") -or $required.Contains($_)
        [ordered]@{ name = $_; enabled = $enable }
    }

    if ($DryRun) {
        $on  = @($modEntries | Where-Object { $_.enabled })
        $off = @($modEntries | Where-Object { -not $_.enabled })
        Write-Info "[DRY-RUN] 将启用 $($on.Count) 个 mod，禁用 $($off.Count) 个 mod"
        return
    }

    # 6. 写回（UTF-8 无 BOM，Factorio 要求）
    if (Test-Path $modListPath) {
        Copy-Item -Path $modListPath -Destination "$modListPath.bak" -Force
        Write-Info "已备份原 mod-list.json → mod-list.json.bak"
    }
    $json = [ordered]@{ mods = @($modEntries) } | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText(
        $modListPath, $json,
        [System.Text.UTF8Encoding]::new($false))

    $on  = @($modEntries | Where-Object { $_.enabled }).Count
    $off = @($modEntries | Where-Object { -not $_.enabled }).Count
    Write-Info "mod-list.json 已更新：$on 个启用，$off 个禁用"
}

# ─── 主流程 ────────────────────────────────────────────────────────────────────
$script:ResolvedModsDir = Get-ModsDir

try {
    Write-Host ""
    Write-Host "=============================="
    Write-Host " SeaBlock 模组安装脚本"
    Write-Host "=============================="
    Write-Host "  mods 目录：$script:ResolvedModsDir"
    if ($Full) {
        Write-Host "  模式：完整安装（mods + 翻译）" -ForegroundColor Cyan
    } else {
        Write-Host "  模式：仅更新翻译（使用 -Full 执行完整安装）" -ForegroundColor Cyan
    }
    if ($DryRun) { Write-Host "  模式：DRY-RUN（不实际写入）" -ForegroundColor Yellow }
    Write-Host ""

    if ($Full) {
        Install-ModsLock
        Write-Host ""
        Install-ExtraMods
        Write-Host ""
    }
    Install-Self
    Write-Host ""
    Update-ModList

    Write-Host ""
    Write-Info "安装完成！请打开 Factorio 并在模组界面确认所有 mod 均已启用。"
} catch {
    Write-Err "安装失败：$_"
    exit 1
}
