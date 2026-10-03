# Helpers for talking to the jailbroken iPad over SSH (dot-source this file).
#   . .\tools\ipad.ps1
#   Invoke-IPad 'uname -a'
#   Install-IPadPackage -IpaPath .\packages\run-<id>\Surfari-1.0.0.ipa -DebPath .\packages\run-<id>\Surfari-1.0.0.deb
#   Set-IPadDebugKey                       # puts "debugKey" of tools/local.json on the device (developer mode)
#   Invoke-Surfari snapshot                # surfari:snapshot?key=<debug key> through uiopen
#   Invoke-Surfari eval @{ js = 'document.title' }
#   Get-IPadCrashLogs
#   Get-IPadSyslog
# The iPad's address and the debug key come from tools/local.json ("ipad", "debugKey"; see tools/local.example.json),
# or -IPadHost on each call.

$script:IPadKey = Join-Path $env:USERPROFILE '.ssh\ipad_ios6'
$script:IPadDefaultHost = ''
$script:IPadDebugKey = ''
$script:IPadLocalCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $script:IPadLocalCfg) {
    try {
        $c = Get-Content $script:IPadLocalCfg -Raw | ConvertFrom-Json
        if ($c.ipad) { $script:IPadDefaultHost = $c.ipad }
        if ($c.debugKey) { $script:IPadDebugKey = $c.debugKey }
    } catch {}
}

function Get-IPadSshArgs {
    # (keepalives end a session whose Wi-Fi link died instead of waiting for ever)
    @('-i', $script:IPadKey, '-oHostKeyAlgorithms=+ssh-rsa', '-oStrictHostKeyChecking=accept-new', '-oConnectTimeout=10', '-oBatchMode=yes', '-oLogLevel=ERROR',
      '-oServerAliveInterval=5', '-oServerAliveCountMax=4')
}

function Assert-IPadHost([string]$IPadHost) {
    if (-not $IPadHost) { throw 'No iPad address: set "ipad" in tools/local.json (see tools/local.example.json) or pass -IPadHost' }
}

# Runs a command on the iPad and returns stdout+stderr as plain strings (never throws on stderr output).
function Invoke-IPad {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPadHost = $script:IPadDefaultHost)
    Assert-IPadHost $IPadHost
    $ErrorActionPreference = 'Continue'   # function-local: native stderr must not become a terminating error
    $sshArgs = Get-IPadSshArgs
    & ssh.exe @sshArgs "root@$IPadHost" $Command 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
}

function Copy-ToIPad {
    param([Parameter(Mandatory = $true)][string]$LocalPath, [Parameter(Mandatory = $true)][string]$RemotePath, [string]$IPadHost = $script:IPadDefaultHost)
    Assert-IPadHost $IPadHost
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs $LocalPath "root@${IPadHost}:$RemotePath" 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $LocalPath" }
}

function Copy-FromIPad {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$LocalPath, [string]$IPadHost = $script:IPadDefaultHost)
    Assert-IPadHost $IPadHost
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs -r "root@${IPadHost}:$RemotePath" $LocalPath 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $RemotePath" }
}

# Installs the IPA (AppSync Unified + ipainstaller or appinst), else the .deb; -BrmemPath also copies the brmem tool to
# /usr/bin (it is no longer in the .deb). The kind already on the device is kept: the IPA and the .deb share one
# bundle id, and with both installed only one shows on the home screen, without the other's data. So an installed
# .deb is updated instead of adding the IPA, and the .deb is never the fallback while an IPA copy is there (its
# preinst would refuse anyway).
function Install-IPadPackage {
    param([string]$IpaPath, [string]$DebPath, [string]$BrmemPath, [string]$IPadHost = $script:IPadDefaultHost)
    $installed = $false
    # (-9: a plain killall can leave the app running; Browser is the name of builds before the rename)
    Invoke-IPad -IPadHost $IPadHost -Command 'killall -9 Surfari 2>/dev/null; killall -9 Browser 2>/dev/null; echo stopped' | Out-Null
    # (the bundle id is plain ASCII in a binary Info.plist as well)
    $state = Invoke-IPad -IPadHost $IPadHost -Command ('for d in /Applications/Surfari.app /Applications/Browser.app; do grep -q com.samcejko.browser $d/Info.plist 2>/dev/null && echo DEB_APP=$d; done; ' +
        'for d in /var/mobile/Applications/*/Surfari.app /var/mobile/Applications/*/Browser.app; do grep -q com.samcejko.browser $d/Info.plist 2>/dev/null && echo IPA_APP=$d; done; true') | Out-String
    $debApp = if ($state -match 'DEB_APP=(\S+)') { $Matches[1] } else { '' }
    $ipaApp = if ($state -match 'IPA_APP=(\S+)') { $Matches[1] } else { '' }
    if ($debApp -and $IpaPath) {
        if (-not ($DebPath -and (Test-Path $DebPath))) {
            throw "The .deb is installed ($debApp): an IPA next to it would share its bundle id. Pass -DebPath to update it, or remove it first (dpkg -r com.samcejko.browser)."
        }
        Write-Host "The .deb is installed ($debApp): updating it instead of installing the IPA"
        $IpaPath = ''
    }
    if ($IpaPath -and (Test-Path $IpaPath)) {
        Write-Host "Installing IPA $IpaPath ..."
        Copy-ToIPad -LocalPath $IpaPath -RemotePath '/tmp/surfari.ipa' -IPadHost $IPadHost
        $out = Invoke-IPad -IPadHost $IPadHost -Command 'if command -v ipainstaller >/dev/null 2>&1; then ipainstaller -f /tmp/surfari.ipa; echo "IPA_EXIT=$?"; elif command -v appinst >/dev/null 2>&1; then appinst /tmp/surfari.ipa; echo "IPA_EXIT=$?"; else echo NO_INSTALLER; fi' | Out-String
        Write-Host $out
        # ipainstaller's exit code is not reliable; trust its own success message as well.
        if ($out -match 'IPA_EXIT=0' -or $out -match '(?i)installed .* successfully') { $installed = $true }
    }
    if (-not $installed -and $DebPath -and (Test-Path $DebPath)) {
        if ($ipaApp) {
            throw "Not installing the .deb: an IPA copy is on the device ($ipaApp) and the two would share one bundle id. Fix the IPA install, or delete that copy first."
        }
        Write-Host "Installing DEB $DebPath (falls back to /Applications) ..."
        Copy-ToIPad -LocalPath $DebPath -RemotePath '/tmp/surfari.deb' -IPadHost $IPadHost
        $out = Invoke-IPad -IPadHost $IPadHost -Command 'dpkg -i /tmp/surfari.deb 2>&1 && { su mobile -c uicache 2>/dev/null || uicache 2>/dev/null; echo DEB_OK; }' | Out-String
        Write-Host $out
        if ($out -match 'DEB_OK') { $installed = $true }
    }
    if (-not $installed) { throw "Nothing installed" }
    if ($BrmemPath -and (Test-Path $BrmemPath)) {
        Copy-ToIPad -LocalPath $BrmemPath -RemotePath '/usr/bin/brmem' -IPadHost $IPadHost
        Invoke-IPad -IPadHost $IPadHost -Command 'chmod 755 /usr/bin/brmem && echo "brmem installed"'
    }
    Write-Host "Done. Tap the Surfari icon on the iPad."
}

# Developer mode on the device: the debug key goes to Library/surfari-debug-key in the app's home - /var/mobile for
# the .deb, the app's container for the IPA (both when both exist). The app reads it at launch: it is killed here.
function Set-IPadDebugKey {
    param([string]$Key = $script:IPadDebugKey, [string]$IPadHost = $script:IPadDefaultHost)
    if (-not $Key -or $Key.Length -lt 16) { throw 'The debug key must have at least 16 characters: set "debugKey" in tools/local.json or pass -Key' }
    if ($Key -notmatch '^[A-Za-z0-9._~-]+$') { throw 'Keep the debug key to letters, digits and . _ ~ - (it travels in surfari: links)' }
    $cmd = "for d in /var/mobile /var/mobile/Applications/*/Surfari.app/..; do " +
           "[ -d `"`$d/Library`" ] || continue; printf '%s\n' '$Key' > `"`$d/Library/surfari-debug-key`"; " +
           "chown mobile:mobile `"`$d/Library/surfari-debug-key`"; chmod 600 `"`$d/Library/surfari-debug-key`"; echo `"key written to `$d/Library`"; done; " +
           "killall -9 Surfari 2>/dev/null; true"
    Invoke-IPad -IPadHost $IPadHost -Command $cmd
}

# Runs a developer command of the app through uiopen: Invoke-Surfari <command> [@{ name = value }]. The debug key is
# added as the first parameter (the app ignores commands without it). Results land in the app's tmp/ and in the log.
function Invoke-Surfari {
    param([Parameter(Mandatory = $true)][string]$Command, [hashtable]$Params = @{}, [string]$Key = $script:IPadDebugKey,
          [string]$IPadHost = $script:IPadDefaultHost)
    if (-not $Key) { throw 'No debug key: set "debugKey" in tools/local.json (and Set-IPadDebugKey once) or pass -Key' }
    $query = 'key=' + [Uri]::EscapeDataString($Key)
    foreach ($k in $Params.Keys) { $query += '&' + $k + '=' + [Uri]::EscapeDataString([string]$Params[$k]) }
    $url = "surfari:$Command`?$query"
    Invoke-IPad -IPadHost $IPadHost -Command ("uiopen '" + $url.Replace("'", "'\''") + "'")
}

function Get-IPadCrashLogs {
    param([string]$IPadHost = $script:IPadDefaultHost, [string]$OutDir = '')
    if (-not $OutDir) { $OutDir = Join-Path (Get-Location) 'packages\crashlogs' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $list = Invoke-IPad -IPadHost $IPadHost -Command 'ls -t /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -i -e surfari -e browser | head -n 5'
    foreach ($f in (@($list) -join "`n" -split "`n" | Where-Object { $_.Trim() })) {
        $name = $f.Trim()
        Copy-FromIPad -IPadHost $IPadHost -RemotePath "/var/mobile/Library/Logs/CrashReporter/$name" -LocalPath (Join-Path $OutDir $name)
        Write-Host "Fetched $name"
    }
    Get-ChildItem $OutDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# (the app logs only in developer mode: a debug key on the device or the BRDebugLog default, see docs/DEVELOPMENT.md)
function Get-IPadSyslog {
    param([string]$IPadHost = $script:IPadDefaultHost, [int]$Lines = 200)
    Invoke-IPad -IPadHost $IPadHost -Command "if [ -f /var/log/syslog ]; then grep -i -e surfari -e browser /var/log/syslog | tail -n $Lines; else echo 'no /var/log/syslog (install the syslogd package from Cydia)'; fi"
}
