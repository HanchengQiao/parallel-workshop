[CmdletBinding()]
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$TargetRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ParallelWorkbench'),
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [switch]$VerifyOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$expectedExtensionID = 'eeppnjgcjioaohaaoaknkkafhodccmmf'
$workbenchURL = 'chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html'

function Write-Step([string]$Message) {
    Write-Host ('[{0,6:N1}s] {1}' -f $timer.Elapsed.TotalSeconds, $Message)
}

function Get-EdgePath {
    $command = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $registryKeys = @(
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )
    foreach ($key in $registryKeys) {
        if (Test-Path -LiteralPath $key) {
            $value = (Get-Item -LiteralPath $key).GetValue('')
            if ($value -and (Test-Path -LiteralPath $value)) { return [string]$value }
        }
    }

    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw '未找到 Microsoft Edge（msedge.exe）'
}

function Assert-ExtensionSource([string]$Path) {
    foreach ($required in @(
        'manifest.json', 'distribution.json', 'background.js', 'content.js', 'workbench.html', 'workbench.js',
        'workbench.css', 'lib\model-preference.js', 'lib\adapters\index.json', 'install.ps1', 'launch.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required))) {
            throw "安装源缺少 $required"
        }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $Path 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.version -or -not $manifest.key) { throw 'manifest.json 缺少版本或固定扩展 ID 公钥' }
    if ([string]$manifest.version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw 'manifest.json 版本号格式无效' }
    try {
        $keyBytes = [Convert]::FromBase64String([string]$manifest.key)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $keyHash = $sha.ComputeHash($keyBytes) } finally { $sha.Dispose() }
        $hexPrefix = -join @($keyHash[0..15] | ForEach-Object { $_.ToString('x2') })
        $idCharacters = foreach ($nibble in $hexPrefix.ToCharArray()) {
            [char](([int][char]'a') + [Convert]::ToInt32([string]$nibble, 16))
        }
        $derivedID = -join $idCharacters
    } catch {
        throw "manifest.json 固定公钥无效：$($_.Exception.Message)"
    }
    if ($derivedID -ne $expectedExtensionID) { throw 'manifest.json 固定公钥与启动器扩展 ID 不一致' }
    return [string]$manifest.version
}

function Move-WithRetry([string]$From, [string]$To, [string]$Description) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Milliseconds (200 * $attempt) }
        }
    }
    throw "$Description 失败：$($lastError.Exception.Message)"
}

function Test-IsSameOrChildPath([string]$Candidate, [string]$Parent) {
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd($separators)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd($separators)
    if ($candidateFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidateFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

$source = (Resolve-Path -LiteralPath $SourceDir).Path
$version = Assert-ExtensionSource $source
if ($VerifyOnly) {
    Write-Step "安装源验证通过：v$version"
    exit 0
}
$edgePath = $null
if ((-not $NoLaunch) -or (-not $NoShortcuts)) { $edgePath = Get-EdgePath }

$targetRootFull = [IO.Path]::GetFullPath($TargetRoot)
$target = Join-Path $targetRootFull 'edge-extension'
$operationID = [Guid]::NewGuid().ToString('N')
$stage = Join-Path $targetRootFull ('.edge-extension.new-' + $operationID)
$backup = Join-Path $targetRootFull ('.edge-extension.old-' + $operationID)

if ($source.Equals($targetRootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SourceDir 不能与 TargetRoot 相同'
}

Write-Step "准备安装 v$version（无需管理员权限）"
New-Item -ItemType Directory -Path $targetRootFull -Force | Out-Null
foreach ($path in @($stage, $backup)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$originalLocation = (Get-Location).Path
$locationWasMoved = $false
$oldWasMoved = $false
$installSucceeded = $false
try {
    # Windows 会锁定进程当前工作目录。用户从已安装目录执行更新时，先移到其父目录。
    if (Test-IsSameOrChildPath $originalLocation $target) {
        Set-Location -LiteralPath $targetRootFull
        $locationWasMoved = $true
    }

    Write-Step '复制并校验扩展文件'
    Get-ChildItem -LiteralPath $source -Force |
        Where-Object { $_.Name -ne '_metadata' -and $_.Name -ne '.DS_Store' } |
        Copy-Item -Destination $stage -Recurse -Force
    $stagedVersion = Assert-ExtensionSource $stage
    if ($stagedVersion -ne $version) { throw '复制后的扩展版本不一致' }

    if (Test-Path -LiteralPath $target) {
        Move-WithRetry $target $backup '备份旧版本'
        $oldWasMoved = $true
    }
    Move-WithRetry $stage $target '启用新版本'
    $installSucceeded = $true
} catch {
    $installError = $_
    if ($oldWasMoved -and (-not (Test-Path -LiteralPath $target)) -and (Test-Path -LiteralPath $backup)) {
        try {
            Move-WithRetry $backup $target '恢复旧版本'
            $oldWasMoved = $false
        } catch {
            throw "安装失败且旧版本自动恢复失败；旧版备份位于 $backup。原错误：$($installError.Exception.Message)"
        }
    }
    throw "安装失败，已保留原版本：$($installError.Exception.Message)"
} finally {
    if ($locationWasMoved) {
        if (Test-Path -LiteralPath $originalLocation) { Set-Location -LiteralPath $originalLocation }
        else { Set-Location -LiteralPath $targetRootFull }
    }
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($installSucceeded -and (Test-Path -LiteralPath $backup)) {
    try { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "新版已安装，但旧版临时备份未能删除：$backup" }
}

if (-not $NoShortcuts) {
    Write-Step '创建桌面与开始菜单快捷方式'
    $shell = New-Object -ComObject WScript.Shell
    $shortcutDirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('Programs')
    ) | Where-Object { $_ }
    foreach ($dir in $shortcutDirs) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $shortcut = $shell.CreateShortcut((Join-Path $dir '平行工作台.lnk'))
            $shortcut.TargetPath = $edgePath
            $shortcut.Arguments = "--app=$workbenchURL"
            $shortcut.WorkingDirectory = (Split-Path -Parent $edgePath)
            $shortcut.IconLocation = $edgePath + ',0'
            $shortcut.Save()
        } catch {
            Write-Warning "快捷方式创建失败（$dir）：$($_.Exception.Message)"
        }
    }
}

$pathNote = Join-Path $targetRootFull 'EXTENSION_PATH.txt'
Set-Content -LiteralPath $pathNote -Value $target -Encoding UTF8
try {
    if (Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue) { Set-Clipboard -Value $target }
    elseif (Get-Command 'clip.exe' -ErrorAction SilentlyContinue) { $target | clip.exe }
} catch {}

if (-not $NoLaunch) {
    Write-Step '打开 Edge 扩展管理页'
    Start-Process -FilePath $edgePath -ArgumentList 'edge://extensions'
}

Write-Step "安装文件已就绪：$target"
Write-Host '首次安装：开启开发人员模式 → 加载解压缩的扩展 → 粘贴已复制的路径。'
Write-Host '已有安装：在扩展卡片点击“重新加载”。'
Write-Host ('完成用时：{0:N1} 秒' -f $timer.Elapsed.TotalSeconds)
