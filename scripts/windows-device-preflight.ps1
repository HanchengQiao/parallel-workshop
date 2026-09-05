[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ParallelWorkbench'),
    [string]$Repository = 'porcelaintech/parallel-workshop',
    [ValidateRange(1, 60)]
    [int]$NetworkTimeoutSeconds = 5,
    [switch]$FailOnIssues
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$checks = New-Object 'System.Collections.Generic.List[object]'

function Add-Check([string]$Name, [string]$Status, [string[]]$RequiredFor, [object]$Details) {
    $checks.Add([pscustomobject][ordered]@{
        name = $Name
        status = $Status
        requiredFor = @($RequiredFor)
        details = $Details
    }) | Out-Null
}

function Get-EdgePath {
    $command = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($command) { return [string]$command.Source }

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

    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return [string]$candidate }
    }
    return $null
}

function Test-TcpEndpoint([string]$HostName, [int]$Port, [int]$TimeoutSeconds) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne([Math]::Max(1, $TimeoutSeconds) * 1000, $false)) {
            return $false
        }
        $client.EndConnect($pending)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-PathAccessAssessment([string]$RequestedPath) {
    $fullPath = [IO.Path]::GetFullPath($RequestedPath)
    $ancestor = $fullPath
    while (-not (Test-Path -LiteralPath $ancestor)) {
        $parent = Split-Path -Parent $ancestor
        if (-not $parent -or $parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    if (-not (Test-Path -LiteralPath $ancestor)) {
        return [pscustomobject][ordered]@{
            requestedPath = $fullPath
            existingAncestor = $null
            owner = $null
            appearsWritable = $false
            method = 'ACL inspection only; no probe file was created'
            error = 'No existing ancestor could be inspected'
        }
    }

    try {
        $acl = Get-Acl -LiteralPath $ancestor
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $sidValues = @()
        if ($identity.User) { $sidValues += $identity.User.Value }
        foreach ($group in $identity.Groups) { $sidValues += $group.Value }

        $writeMask = [int64](
            [Security.AccessControl.FileSystemRights]::Write -bor
            [Security.AccessControl.FileSystemRights]::Modify -bor
            [Security.AccessControl.FileSystemRights]::FullControl -bor
            [Security.AccessControl.FileSystemRights]::CreateFiles -bor
            [Security.AccessControl.FileSystemRights]::CreateDirectories
        )
        $allowed = $false
        $denied = $false
        $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ($sidValues -notcontains $rule.IdentityReference.Value) { continue }
            if (([int64]$rule.FileSystemRights -band $writeMask) -eq 0) { continue }
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny) { $denied = $true }
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) { $allowed = $true }
        }

        return [pscustomobject][ordered]@{
            requestedPath = $fullPath
            existingAncestor = $ancestor
            owner = [string]$acl.Owner
            appearsWritable = [bool]($allowed -and -not $denied)
            method = 'ACL inspection only; no probe file was created'
            error = $null
        }
    } catch {
        return [pscustomobject][ordered]@{
            requestedPath = $fullPath
            existingAncestor = $ancestor
            owner = $null
            appearsWritable = $false
            method = 'ACL inspection only; no probe file was created'
            error = $_.Exception.Message
        }
    }
}

function Test-GitHubDownloadRoute([string]$Repo, [int]$TimeoutSeconds) {
    $details = [ordered]@{
        repository = $Repo
        apiReached = $false
        assetHeadReached = $false
        assetName = $null
        httpStatus = $null
        error = $null
    }
    try {
        if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository 格式无效' }
        $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'ParallelWorkbench-Windows-Preflight' }
        $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec $TimeoutSeconds
        $details.apiReached = $true
        $asset = @($release.assets | Where-Object { $_.name -eq 'edge-extension.zip' }) | Select-Object -First 1
        if (-not $asset) { throw 'Latest Release 缺少 edge-extension.zip' }
        $details.assetName = [string]$asset.name
        $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri ([string]$asset.browser_download_url) -Headers $headers -TimeoutSec $TimeoutSeconds
        $details.httpStatus = [int]$response.StatusCode
        $details.assetHeadReached = $response.StatusCode -ge 200 -and $response.StatusCode -lt 400
    } catch {
        $details.error = $_.Exception.Message
    }
    return [pscustomobject]$details
}

function Test-ScopeReady([string]$Scope) {
    foreach ($check in $checks) {
        if (@($check.requiredFor) -contains $Scope -and $check.status -ne 'PASS') { return $false }
    }
    return $true
}

$isWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$osDetails = [ordered]@{
    platform = [Environment]::OSVersion.Platform.ToString()
    version = [Environment]::OSVersion.Version.ToString()
    caption = $null
    architecture = $env:PROCESSOR_ARCHITECTURE
}
if ($isWindows -and (Get-Command 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $osDetails.caption = [string]$os.Caption
        $osDetails.version = [string]$os.Version
    } catch {}
}
Add-Check 'os.windows' $(if ($isWindows) { 'PASS' } else { 'FAIL' }) @('installer', 'remote') ([pscustomobject]$osDetails)

$psVersion = $PSVersionTable.PSVersion
$psCompatible = $psVersion.Major -gt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -ge 1)
Add-Check 'powershell.compatible' $(if ($psCompatible) { 'PASS' } else { 'FAIL' }) @('installer', 'remote') ([pscustomobject][ordered]@{
    version = $psVersion.ToString()
    edition = $(if ($PSVersionTable.PSObject.Properties.Name -contains 'PSEdition') { [string]$PSVersionTable.PSEdition } else { 'Desktop' })
    processBitness = [IntPtr]::Size * 8
})

$edgePath = Get-EdgePath
$edgeDetails = [ordered]@{ path = $edgePath; version = $null }
if ($edgePath) {
    try { $edgeDetails.version = [string](Get-Item -LiteralPath $edgePath).VersionInfo.ProductVersion } catch {}
}
Add-Check 'edge.installed' $(if ($edgePath) { 'PASS' } else { 'FAIL' }) @('installer', 'remote') ([pscustomobject]$edgeDetails)

$sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
$sshdCommand = Get-Command 'sshd.exe' -ErrorAction SilentlyContinue
$sshClient = Get-Command 'ssh.exe' -ErrorAction SilentlyContinue
$sshdRunning = $sshdService -and $sshdService.Status -eq 'Running'
Add-Check 'openssh.server' $(if ($sshdRunning) { 'PASS' } else { 'FAIL' }) @('remote') ([pscustomobject][ordered]@{
    installed = [bool]($sshdService -or $sshdCommand)
    serviceStatus = $(if ($sshdService) { [string]$sshdService.Status } else { 'NotInstalled' })
    serverPath = $(if ($sshdCommand) { [string]$sshdCommand.Source } else { $null })
    clientPath = $(if ($sshClient) { [string]$sshClient.Source } else { $null })
})

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$authorizedKeyCandidates = @()
if ($isAdministrator) {
    if ($env:ProgramData) { $authorizedKeyCandidates += (Join-Path $env:ProgramData 'ssh\administrators_authorized_keys') }
} elseif ($env:USERPROFILE) {
    $authorizedKeyCandidates += (Join-Path $env:USERPROFILE '.ssh\authorized_keys')
}
$existingAuthorizedKeyFiles = @($authorizedKeyCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
Add-Check 'openssh.authorizedKeys' $(if ($existingAuthorizedKeyFiles.Count -gt 0) { 'PASS' } else { 'FAIL' }) @('remote') ([pscustomobject][ordered]@{
    currentUserIsAdministrator = $isAdministrator
    candidates = $authorizedKeyCandidates
    existingFiles = $existingAuthorizedKeyFiles
    contentsRead = $false
    note = 'Checks the default OpenSSH key file for this account type; existence does not prove that the Mac key can log in.'
})

$port22Listening = $false
try {
    if (Get-Command 'Get-NetTCPConnection' -ErrorAction SilentlyContinue) {
        $port22Listening = @(
            Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction Stop
        ).Count -gt 0
    } else {
        $port22Listening = @(& netstat.exe -ano -p tcp 2>$null | Select-String -Pattern '^\s*TCP\s+\S+:22\s+\S+\s+LISTENING\s+\d+\s*$').Count -gt 0
    }
} catch {}
Add-Check 'openssh.port22' $(if ($port22Listening) { 'PASS' } else { 'FAIL' }) @('remote') ([pscustomobject]@{ listening = $port22Listening })

$firewallDetails = [ordered]@{ ruleFound = $false; enabled = $false; direction = $null; action = $null }
if (Get-Command 'Get-NetFirewallRule' -ErrorAction SilentlyContinue) {
    try {
        $firewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction Stop | Select-Object -First 1
        if ($firewallRule) {
            $firewallDetails.ruleFound = $true
            $firewallDetails.enabled = [string]$firewallRule.Enabled -eq 'True'
            $firewallDetails.direction = [string]$firewallRule.Direction
            $firewallDetails.action = [string]$firewallRule.Action
        }
    } catch {}
}
$firewallReady = $firewallDetails.enabled -and $firewallDetails.direction -eq 'Inbound' -and $firewallDetails.action -eq 'Allow'
Add-Check 'openssh.firewallHint' $(if ($firewallReady) { 'PASS' } else { 'WARN' }) @() ([pscustomobject]$firewallDetails)

$localIPv4 = @()
if (Get-Command 'Get-NetIPAddress' -ErrorAction SilentlyContinue) {
    try {
        $localIPv4 = @(
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.AddressState -ne 'Tentative' } |
                ForEach-Object { [pscustomobject]@{ address = $_.IPAddress; interface = $_.InterfaceAlias } }
        )
    } catch {}
}
if ($localIPv4.Count -eq 0) {
    try {
        $localIPv4 = @(
            [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and -not [Net.IPAddress]::IsLoopback($_) } |
                ForEach-Object { [pscustomobject]@{ address = $_.IPAddressToString; interface = $null } }
        )
    } catch {}
}
Add-Check 'network.localIPv4' $(if ($localIPv4.Count -gt 0) { 'PASS' } else { 'FAIL' }) @('remote') $localIPv4

$githubAddresses = @()
try { $githubAddresses = @([Net.Dns]::GetHostAddresses('api.github.com') | ForEach-Object { $_.IPAddressToString }) } catch {}
$githubTcp = Test-TcpEndpoint 'api.github.com' 443 $NetworkTimeoutSeconds
$githubRoute = Test-GitHubDownloadRoute $Repository $NetworkTimeoutSeconds
$githubStatus = if ($githubRoute.apiReached -and $githubRoute.assetHeadReached) { 'PASS' } else { 'FAIL' }
$githubDetails = [ordered]@{}
foreach ($property in $githubRoute.PSObject.Properties) { $githubDetails[$property.Name] = $property.Value }
$githubDetails.directTcpReachable = $githubTcp
$githubDetails.dnsAddresses = $githubAddresses
$githubDetails.note = 'HTTP result uses the same proxy-aware PowerShell web stack as the installer; direct TCP is informational only.'
Add-Check 'network.githubDownloadRoute' $githubStatus @('installer') ([pscustomobject]$githubDetails)

$installAccess = Get-PathAccessAssessment $InstallRoot
Add-Check 'path.installRoot.resolvable' $(if ($installAccess.existingAncestor) { 'PASS' } else { 'FAIL' }) @('installer') $installAccess
Add-Check 'path.installRoot.aclWriteHint' $(if ($installAccess.appearsWritable) { 'PASS' } else { 'WARN' }) @() $installAccess
$tempAccess = Get-PathAccessAssessment ([IO.Path]::GetTempPath())
Add-Check 'path.temp.resolvable' $(if ($tempAccess.existingAncestor) { 'PASS' } else { 'FAIL' }) @('installer', 'remote') $tempAccess
Add-Check 'path.temp.aclWriteHint' $(if ($tempAccess.appearsWritable) { 'PASS' } else { 'WARN' }) @() $tempAccess

$readyForInstaller = Test-ScopeReady 'installer'
$readyForRemote = Test-ScopeReady 'remote'
$issues = @($checks | Where-Object { $_.status -ne 'PASS' } | ForEach-Object { '{0}: {1}' -f $_.name, $_.status })
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    computerName = $env:COMPUTERNAME
    currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    readOnly = $true
    readyForInstallerTest = $readyForInstaller
    windowsHostReadyForMacSshProbe = $readyForRemote
    remoteLoginVerified = $false
    writePermissionRequiresLiveTest = $true
    checks = $checks.ToArray()
    issues = $issues
}
$result | ConvertTo-Json -Depth 8

if ($FailOnIssues -and (-not $readyForInstaller -or -not $readyForRemote)) { exit 2 }
exit 0
