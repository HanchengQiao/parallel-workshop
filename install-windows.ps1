[CmdletBinding()]
param(
    [string]$Repository = 'porcelaintech/parallel-workshop',
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ParallelWorkbench'),
    [string]$ArchivePath = '',
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [switch]$VerifyOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$timer = [Diagnostics.Stopwatch]::StartNew()
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N'))

function Write-Step([string]$Message) {
    Write-Host ('[{0,6:N1}s] {1}' -f $timer.Elapsed.TotalSeconds, $Message)
}

function Invoke-WithRetry([scriptblock]$Operation, [string]$Description) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return & $Operation } catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
        }
    }
    throw "$Description 失败（已重试 3 次）：$($lastError.Exception.Message)"
}

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $zip = Join-Path $temp 'edge-extension.zip'
    $expectedDigest = ''
    $releaseVersion = ''

    if ($ArchivePath) {
        Write-Step '使用本地候选包'
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ArchivePath).Path -Destination $zip
    } else {
        Write-Step '读取 GitHub 最新稳定版本'
        $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'ParallelWorkbench-Windows-Installer' }
        $api = "https://api.github.com/repos/$Repository/releases/latest"
        $release = Invoke-WithRetry { Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30 } '获取版本信息'
        if ($release.draft -or $release.prerelease) { throw '最新 Release 不是稳定版本' }
        $asset = @($release.assets | Where-Object { $_.name -eq 'edge-extension.zip' }) | Select-Object -First 1
        if (-not $asset) { throw 'Release 缺少 edge-extension.zip' }
        $releaseVersion = ([string]$release.tag_name).TrimStart('v')
        if ($releaseVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw 'Release 版本号格式无效' }
        if ($asset.PSObject.Properties.Name -contains 'digest') {
            $expectedDigest = ([string]$asset.digest) -replace '^sha256:', ''
        }
        if ($expectedDigest -notmatch '^[0-9a-fA-F]{64}$') {
            $match = [regex]::Match([string]$release.body, '(?im)^SHA256\s+edge-extension\.zip\s+([0-9a-f]{64})\s*$')
            if ($match.Success) { $expectedDigest = $match.Groups[1].Value }
        }
        if ($expectedDigest -notmatch '^[0-9a-fA-F]{64}$') { throw 'Release 未提供有效 SHA-256' }

        Write-Step "下载 v$releaseVersion（文件约 100 KB）"
        Invoke-WithRetry {
            Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -Headers $headers -OutFile $zip -TimeoutSec 60
        } '下载安装包' | Out-Null
        $actualDigest = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualDigest -ne $expectedDigest.ToLowerInvariant()) { throw 'SHA-256 校验失败' }
        Write-Step 'SHA-256 校验通过'
    }

    Write-Step '解压安装包'
    $expanded = Join-Path $temp 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
    $source = Join-Path $expanded 'edge-extension'
    if (-not (Test-Path -LiteralPath (Join-Path $source 'manifest.json'))) {
        if (Test-Path -LiteralPath (Join-Path $expanded 'manifest.json')) { $source = $expanded }
        else { throw '压缩包目录结构无效' }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($releaseVersion -and ([string]$manifest.version -ne $releaseVersion)) { throw 'Release 与 manifest 版本不一致' }
    if (-not (Test-Path -LiteralPath (Join-Path $source 'install.ps1'))) { throw '安装包缺少 install.ps1' }

    if ($VerifyOnly) {
        Write-Step "下载、校验和解压通过：v$($manifest.version)"
        exit 0
    }

    $parameters = @{
        SourceDir = $source
        TargetRoot = $InstallRoot
        NoLaunch = [bool]$NoLaunch
        NoShortcuts = [bool]$NoShortcuts
    }
    & (Join-Path $source 'install.ps1') @parameters
    Write-Step "全部完成：v$($manifest.version)"
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
