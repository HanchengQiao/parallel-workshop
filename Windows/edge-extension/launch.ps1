[CmdletBinding()]
param([switch]$PrintOnly)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$workbenchURL = 'chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html'

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

$edge = Get-EdgePath
if ($PrintOnly) {
    [pscustomobject]@{ EdgePath = $edge; WorkbenchURL = $workbenchURL; Arguments = "--app=$workbenchURL" } |
        ConvertTo-Json -Compress
    exit 0
}
Start-Process -FilePath $edge -ArgumentList "--app=$workbenchURL"
exit 0
