Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Braintrust-installer-test-' + [Guid]::NewGuid().ToString('N'))

# 只载入被测函数；不执行安装器主流程、不读取真实 Edge 配置、不启动浏览器。
foreach ($relative in @('install-windows.ps1', 'Windows/edge-extension/launch.ps1', 'Windows/edge-extension/install.ps1')) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $relative), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failed: $relative" }
    $definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Write-Profile([string]$Name, [string]$PreferenceFile, [string]$ExtensionPath, [int]$State) {
    $directory = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $settings = @{}
    $settings['eeppnjgcjioaohaaoaknkkafhodccmmf'] = @{ path = $ExtensionPath; state = $State }
    @{ extensions = @{ settings = $settings } } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $directory $PreferenceFile) -Encoding UTF8
}

$script:httpCalls = @()
$script:indexResponse = $null
$script:apiResponse = $null
function Invoke-RestMethod([string]$Uri, $Headers, [int]$TimeoutSec) {
    $script:httpCalls += [pscustomobject]@{ URL = $Uri; Timeout = $TimeoutSec }
    if ($Uri.EndsWith('/update.json')) {
        if ($null -eq $script:indexResponse) { throw 'index network unavailable' }
        return $script:indexResponse
    }
    if ($null -eq $script:apiResponse) { throw 'API unavailable' }
    return $script:apiResponse
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $extensionPath = Join-Path $testRoot '安装 中文 空格/edge-extension'
    $empty = Get-ExtensionRegistration $testRoot $extensionPath
    Assert-True (-not $empty.Enabled -and $empty.ProfileDirectory -eq 'Default') 'Fresh installation must require first Edge loading'
    @{ profile = @{ last_used = 'Profile 2' } } | ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath (Join-Path $testRoot 'Local State') -Encoding UTF8
    $preferred = Get-ExtensionRegistration $testRoot $extensionPath
    Assert-True ($preferred.ProfileDirectory -eq 'Profile 2' -and -not $preferred.Enabled) 'First loading must use the active normal profile'

    Write-Profile 'Default' 'Secure Preferences' (Join-Path $testRoot 'old-download/edge-extension') 1
    $legacy = Get-ExtensionRegistration $testRoot $extensionPath
    Assert-True ($legacy.Enabled -and -not $legacy.PathMatches) 'A registered legacy directory must not be treated as the newly installed directory'
    Write-Profile 'Profile 1' 'Secure Preferences' $extensionPath 1
    $installed = Get-ExtensionRegistration $testRoot $extensionPath
    Assert-True ($installed.Enabled -and $installed.PathMatches -and $installed.ProfileDirectory -eq 'Profile 1') 'Must launch the profile that actually loaded this installation'
    Write-Profile 'Profile 1' 'Secure Preferences' $extensionPath 0
    Write-Profile 'Profile 1' 'Preferences' $extensionPath 1
    $disabled = Get-ExtensionRegistration $testRoot $extensionPath
    Assert-True (-not ($disabled.Enabled -and $disabled.PathMatches)) 'Stale Preferences must not override a disabled Secure Preferences registration'
    $newSettings = @{}
    $newSettings['eeppnjgcjioaohaaoaknkkafhodccmmf'] = @{ path = $extensionPath }
    @{ extensions = @{ settings = $newSettings } } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $testRoot 'Profile 1/Secure Preferences') -Encoding UTF8
    $newEdge = Get-ExtensionRegistration $testRoot $extensionPath
    Assert-True ($newEdge.Enabled -and $newEdge.PathMatches) 'New Edge entries with no state or disable_reasons are enabled'
    $newSettings['eeppnjgcjioaohaaoaknkkafhodccmmf']['disable_reasons'] = @(1)
    @{ extensions = @{ settings = $newSettings } } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $testRoot 'Profile 1/Secure Preferences') -Encoding UTF8
    $newDisabled = Get-ExtensionRegistration $testRoot $extensionPath
    Assert-True (-not ($newDisabled.Enabled -and $newDisabled.PathMatches)) 'New Edge disable_reasons must prevent treating a disabled extension as ready'

    $validShortcut = [pscustomobject]@{ TargetPath = 'msedge.exe'; Arguments = '--app=chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html' }
    $unrelatedShortcut = [pscustomobject]@{ TargetPath = 'other.exe'; Arguments = '' }
    Assert-True (Test-ProductShortcut $validShortcut $testRoot) 'Existing product shortcut should migrate'
    Assert-True (-not (Test-ProductShortcut $unrelatedShortcut $testRoot)) 'Same-name unrelated shortcut must be preserved'
    $newStartURL = [Uri]::new((Join-Path $testRoot 'edge-extension\start.html'), [UriKind]::Absolute).AbsoluteUri
    $newShortcut = [pscustomobject]@{ TargetPath = 'msedge.exe'; Arguments = '--profile-directory="Default" --app="' + $newStartURL + '"' }
    Assert-True (Test-ProductShortcut $newShortcut $testRoot) 'New visible-startup shortcut must remain updatable'

    $digest = 'a' * 64
    $url = 'https://github.com/porcelaintech/parallel-workshop/releases/download/v9.8.7/edge-extension.zip'
    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = '9.8.7'; edgeURL = $url; edgeSHA256 = $digest }
    $package = Get-LatestPackage 'porcelaintech/parallel-workshop'
    Assert-True ($package.URL -eq $url -and $package.SHA256 -eq $digest) 'Official index must select the expected archive and digest'
    Assert-True ($script:httpCalls.Count -eq 1 -and $script:httpCalls[0].Timeout -eq 12) 'Successful index must avoid all API requests'

    $script:httpCalls = @()
    $script:indexResponse = $null
    $script:apiResponse = [pscustomobject]@{
        draft = $false; prerelease = $false; tag_name = 'v9.8.7'; body = ''
        assets = @(
            [pscustomobject]@{ name = 'edge-extension-store.zip'; digest = 'sha256:' + $digest; browser_download_url = 'https://example.invalid/store.zip' },
            [pscustomobject]@{ name = 'edge-extension.zip'; digest = 'sha256:' + $digest; browser_download_url = $url }
        )
    }
    $fallback = Get-LatestPackage 'porcelaintech/parallel-workshop'
    Assert-True ($fallback.URL -eq $url -and $script:httpCalls.Count -eq 2) 'Index outage must use one bounded API fallback and select the user ZIP'
    Assert-True ($script:httpCalls[1].Timeout -eq 12) 'API fallback must retain a short request deadline'

    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = '9.8.7'; edgeURL = 'https://example.invalid/edge-extension.zip'; edgeSHA256 = $digest }
    $script:apiResponse = $null
    $rejected = $false
    try { Get-LatestPackage 'porcelaintech/parallel-workshop' | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Untrusted archive URL must not be returned for downloading'
    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = '9.8.7'; edgeURL = $url; edgeSHA256 = '' }
    $rejected = $false
    try { Get-LatestPackage 'porcelaintech/parallel-workshop' | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Missing digest must fail closed'

    $sourceDir = Join-Path $repoRoot 'Windows/edge-extension'
    $installRoot = Join-Path $testRoot '安装 中文 空格'
    $installedDir = Join-Path $installRoot 'edge-extension'
    & (Join-Path $sourceDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard
    Set-Content -LiteralPath (Join-Path $installedDir 'obsolete-old-release.js') -Value 'obsolete'
    New-Item -ItemType Directory -Path (Join-Path $installedDir '_metadata') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installedDir '_metadata/stale-cache') -Value 'stale'
    & (Join-Path $sourceDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedDir 'obsolete-old-release.js'))) 'Replacing from a fresh package must remove files deleted by the new release'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedDir '_metadata'))) 'Replacing the product must discard stale product metadata'
    Push-Location $installedDir
    try { & (Join-Path $installedDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard }
    finally { Pop-Location }

    $script:simulateStageFailure = $true
    function Move-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Destination)
        if ($script:simulateStageFailure -and (Split-Path -Leaf $LiteralPath) -like '.edge-extension.new-*') { throw 'simulated Windows file lock during activation' }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    Set-Content -LiteralPath (Join-Path $installedDir 'previous-version-marker') -Value 'preserve on rollback'
    $rolledBack = $false
    try { & (Join-Path $sourceDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard }
    catch { $rolledBack = $true }
    $script:simulateStageFailure = $false
    Assert-True $rolledBack 'A failed activation must report failure'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedDir 'previous-version-marker')) 'A failed activation must restore the original complete installation'
    Assert-True (@(Get-ChildItem -LiteralPath $installRoot -Force | Where-Object { $_.Name -like '.edge-extension.*' }).Count -eq 0) 'Successful rollback must remove staging and backup directories'
    Write-Host 'PASS: Windows installer behavior (index, fallback, profile, legacy path, shortcuts, clean replacement, self-update, rollback)'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
