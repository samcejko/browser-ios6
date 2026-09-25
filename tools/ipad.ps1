# Helpers for talking to the jailbroken iPad over SSH (dot-source this file).
#   . .\tools\ipad.ps1
#   Invoke-IPad 'uname -a'
#   Install-IPadPackage -IpaPath .\packages\Browser-0.1.0.ipa -DebPath .\packages\com.samcejko.browser_0.1.0_iphoneos-arm.deb
#   Get-IPadCrashLogs
#   Get-IPadSyslog

$script:IPadKey = Join-Path $env:USERPROFILE '.ssh\ipad_ios6'
$script:IPadDefaultHost = '192.168.137.17'
$script:IPadLocalCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $script:IPadLocalCfg) {
    try {
        $c = Get-Content $script:IPadLocalCfg -Raw | ConvertFrom-Json
        if ($c.ipad) { $script:IPadDefaultHost = $c.ipad }
    } catch {}
}

function Get-IPadSshArgs {
    # (keepalives end a session whose Wi-Fi link died instead of waiting for ever)
    @('-i', $script:IPadKey, '-oHostKeyAlgorithms=+ssh-rsa', '-oStrictHostKeyChecking=accept-new', '-oConnectTimeout=10', '-oBatchMode=yes', '-oLogLevel=ERROR',
      '-oServerAliveInterval=5', '-oServerAliveCountMax=4')
}

# Runs a command on the iPad and returns stdout+stderr as plain strings (never throws on stderr output).
function Invoke-IPad {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'   # function-local: native stderr must not become a terminating error
    $sshArgs = Get-IPadSshArgs
    & ssh.exe @sshArgs "root@$IPadHost" $Command 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
}

function Copy-ToIPad {
    param([Parameter(Mandatory = $true)][string]$LocalPath, [Parameter(Mandatory = $true)][string]$RemotePath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs $LocalPath "root@${IPadHost}:$RemotePath" 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $LocalPath" }
}

function Copy-FromIPad {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$LocalPath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs -r "root@${IPadHost}:$RemotePath" $LocalPath 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $RemotePath" }
}

function Install-IPadPackage {
    param([string]$IpaPath, [string]$DebPath, [string]$IPadHost = $script:IPadDefaultHost)
    $installed = $false
    Invoke-IPad -IPadHost $IPadHost -Command 'killall Browser 2>/dev/null; echo stopped' | Out-Null
    if ($IpaPath -and (Test-Path $IpaPath)) {
        Write-Host "Installing IPA $IpaPath ..."
        Copy-ToIPad -LocalPath $IpaPath -RemotePath '/tmp/browser.ipa' -IPadHost $IPadHost
        $out = Invoke-IPad -IPadHost $IPadHost -Command 'if command -v ipainstaller >/dev/null 2>&1; then ipainstaller -f /tmp/browser.ipa; echo "IPA_EXIT=$?"; elif command -v appinst >/dev/null 2>&1; then appinst /tmp/browser.ipa; echo "IPA_EXIT=$?"; else echo NO_INSTALLER; fi' | Out-String
        Write-Host $out
        # ipainstaller's exit code is not reliable; trust its own success message as well.
        if ($out -match 'IPA_EXIT=0' -or $out -match '(?i)installed .* successfully') { $installed = $true }
    }
    if (-not $installed -and $DebPath -and (Test-Path $DebPath)) {
        Write-Host "Installing DEB $DebPath (falls back to /Applications) ..."
        Copy-ToIPad -LocalPath $DebPath -RemotePath '/tmp/browser.deb' -IPadHost $IPadHost
        $out = Invoke-IPad -IPadHost $IPadHost -Command 'dpkg -i /tmp/browser.deb 2>&1 && { uicache 2>/dev/null; echo DEB_OK; }' | Out-String
        Write-Host $out
        if ($out -match 'DEB_OK') { $installed = $true }
    }
    if (-not $installed) { throw "Nothing installed" }
    Write-Host "Done. Tap the Browser icon on the iPad."
}

function Get-IPadCrashLogs {
    param([string]$IPadHost = $script:IPadDefaultHost, [string]$OutDir = '')
    if (-not $OutDir) { $OutDir = Join-Path (Get-Location) 'packages\crashlogs' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $list = Invoke-IPad -IPadHost $IPadHost -Command 'ls -t /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -i browser | head -n 5'
    foreach ($f in (@($list) -join "`n" -split "`n" | Where-Object { $_.Trim() })) {
        $name = $f.Trim()
        Copy-FromIPad -IPadHost $IPadHost -RemotePath "/var/mobile/Library/Logs/CrashReporter/$name" -LocalPath (Join-Path $OutDir $name)
        Write-Host "Fetched $name"
    }
    Get-ChildItem $OutDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-IPadSyslog {
    param([string]$IPadHost = $script:IPadDefaultHost, [int]$Lines = 200)
    Invoke-IPad -IPadHost $IPadHost -Command "if [ -f /var/log/syslog ]; then grep -i browser /var/log/syslog | tail -n $Lines; else echo 'no /var/log/syslog (install the syslogd package from Cydia)'; fi"
}
