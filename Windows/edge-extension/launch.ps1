[CmdletBinding()]
param([switch]$PrintOnly)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$workbenchURL = 'chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/launch.html'

function Get-EdgePath {
    $command = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($key in @(
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )) {
        if (Test-Path -LiteralPath $key) {
            $value = (Get-Item -LiteralPath $key).GetValue('')
            if ($value -and (Test-Path -LiteralPath $value)) { return [string]$value }
        }
    }
    foreach ($candidate in @(
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe' }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe' })
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw '未找到 Microsoft Edge（msedge.exe）'
}

function Get-JSONProperty($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-ExtensionRegistration([string]$ProfileRoot, [string]$ExtensionPath) {
    $preferred = 'Default'
    try {
        $localState = Get-Content -LiteralPath (Join-Path $ProfileRoot 'Local State') -Raw -Encoding UTF8 | ConvertFrom-Json
        $lastUsed = [string](Get-JSONProperty (Get-JSONProperty $localState 'profile') 'last_used')
        if ($lastUsed -match '^(Default|Profile \d+)$') { $preferred = $lastUsed }
    } catch {}
    $profiles = @($preferred, 'Default')
    if (Test-Path -LiteralPath $ProfileRoot) {
        $profiles += @(Get-ChildItem -LiteralPath $ProfileRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Default|Profile \d+)$' } | ForEach-Object { $_.Name })
    }
    $fallback = [pscustomobject]@{ Enabled = $false; ProfileDirectory = $preferred; PathMatches = $false }
    foreach ($profile in @($profiles | Select-Object -Unique)) {
        foreach ($file in @('Secure Preferences', 'Preferences')) {
            try {
                $preferences = Get-Content -LiteralPath (Join-Path (Join-Path $ProfileRoot $profile) $file) -Raw -Encoding UTF8 | ConvertFrom-Json
                $settings = Get-JSONProperty (Get-JSONProperty $preferences 'extensions') 'settings'
                $entry = Get-JSONProperty $settings 'eeppnjgcjioaohaaoaknkkafhodccmmf'
                if ($null -eq $entry) { continue }
                # 新版 Edge 的已启用条目可省略 state；停用使用非零 disable_reasons。
                $state = Get-JSONProperty $entry 'state'
                $disableReasons = Get-JSONProperty $entry 'disable_reasons'
                $hasDisableReasons = $null -ne $disableReasons -and @($disableReasons | Where-Object { [string]$_ -ne '0' }).Count -gt 0
                $enabled = ($null -eq $state -or $state -eq 1) -and (-not $hasDisableReasons)
                $registeredPath = [string](Get-JSONProperty $entry 'path')
                $pathMatches = $registeredPath -and [IO.Path]::GetFullPath($registeredPath).TrimEnd('\', '/').Equals(
                    [IO.Path]::GetFullPath($ExtensionPath).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)
                $registration = [pscustomobject]@{ Enabled = [bool]$enabled; ProfileDirectory = $profile; PathMatches = [bool]$pathMatches }
                if ($registration.Enabled -and $registration.PathMatches) { return $registration }
                $fallback = $registration
                # Secure Preferences 的有效记录优先，避免回退到 Preferences 中的旧启用状态。
                break
            } catch {}
        }
    }
    return $fallback
}

$edge = Get-EdgePath
$profileRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Edge\User Data'
$registration = Get-ExtensionRegistration $profileRoot $PSScriptRoot
$startFile = Join-Path $PSScriptRoot 'start.html'
if (-not (Test-Path -LiteralPath $startFile -PathType Leaf)) { throw '智囊启动页缺失，请重新运行官方安装命令' }
$startURL = [Uri]::new($startFile, [UriKind]::Absolute).AbsoluteUri
$arguments = '--profile-directory="' + $registration.ProfileDirectory + '" --app="' + $startURL + '"'
if ($PrintOnly) {
    [pscustomobject]@{
        EdgePath = $edge
        WorkbenchURL = $workbenchURL
        StartURL = $startURL
        Arguments = $arguments
        ProfileDirectory = $registration.ProfileDirectory
        ExtensionReady = $registration.Enabled -and $registration.PathMatches
    } |
        ConvertTo-Json -Compress
    exit 0
}
Start-Process -FilePath $edge -ArgumentList $arguments
exit 0
