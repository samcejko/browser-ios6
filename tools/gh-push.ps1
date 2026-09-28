# Pushes the working tree to GitHub through the REST API (no local git needed).
# Usage: .\tools\gh-push.ps1 [-Repo owner/name] [-Token ghp_xxx] -Message "commit message"
# Repo and token default to tools/local.json ({"repo": "...", "token": "..."}).
param(
    [string]$Repo = '',
    [string]$Token = $env:GH_TOKEN,
    [string]$Branch = '',
    [string]$Message = 'Update',
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$localCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $localCfg) {
    $cfg = Get-Content $localCfg -Raw | ConvertFrom-Json
    if (-not $Repo -and $cfg.repo) { $Repo = $cfg.repo }
    if (-not $Token -and $cfg.token) { $Token = $cfg.token }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Repo) { throw "Missing repo: pass -Repo or set it in tools/local.json" }
if (-not $Token) { throw "Missing token: pass -Token, set GH_TOKEN or tools/local.json" }

$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'browser-ios6-push'
}
$Api = "https://api.github.com/repos/$Repo"

function Invoke-GH {
    param([string]$Method, [string]$Path, $Body)
    $params = @{ Method = $Method; Uri = "$Api$Path"; Headers = $Headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress)) }
    # Freshly created fine-grained tokens return sporadic 403s while permissions propagate; retry those.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod @params
        } catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            $retryable = ($status -eq 403 -or $status -eq 502 -or $status -eq 503 -or $status -eq 0)
            if ($status -eq 403 -and $_.ErrorDetails.Message -match 'rate limit') { $retryable = $true }
            if (-not $retryable -or $attempt -ge 8) { throw }
            Start-Sleep -Seconds ([Math]::Min(3 * $attempt, 20))
        }
    }
}

function Test-Ignored([string]$rel) {
    $r = $rel -replace '\\', '/'
    if ($r -like '.theos/*' -or $r -like 'obj/*' -or $r -like 'packages/*' -or $r -like 'vendor/mbedtls/*' -or $r -like 'vendor/woff2/*' -or $r -like 'vendor/brotli/*' -or $r -like 'vendor/libwebp/*' -or $r -like '.git/*') { return $true }
    if ($r -like 'Resources/Icon*.png' -or $r -like 'Resources/Default*.png' -or $r -eq 'Resources/cacert.pem' -or $r -eq 'Resources/adblock.txt' -or $r -like 'Resources/js/*' -or $r -like 'tools/babel-test/*') { return $true }
    if ($r -like '*.ipa' -or $r -like '*.deb' -or $r -like '*.DS_Store' -or $r -eq 'tools/local.json' -or $r -like '*.log' -or $r -like 'saved/*') { return $true }
    return $false
}

function Get-GitBlobSha([byte[]]$bytes) {
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = New-Object byte[] ($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $all, 0, $header.Length)
    [Array]::Copy($bytes, 0, $all, $header.Length, $bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    return ([BitConverter]::ToString($sha1.ComputeHash($all)) -replace '-', '').ToLower()
}

# 0. Default branch when none was given
if (-not $Branch) {
    $repoInfo = Invoke-GH GET ""
    $Branch = $repoInfo.default_branch
    if (-not $Branch) { $Branch = 'main' }
    Write-Host "Using branch '$Branch'"
}

# 1. Current head (initialise an empty repository through the contents API if needed)
$headSha = $null
try {
    $ref = Invoke-GH GET "/git/ref/heads/$Branch"
    $headSha = $ref.object.sha
} catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    if ($status -eq 409) {
        Write-Host "Repository is empty; creating the initial commit via the contents API"
        $readme = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("# browser-ios6`n"))
        Invoke-GH PUT "/contents/README.md" @{ message = 'Initial commit'; content = $readme; branch = $Branch } | Out-Null
    } elseif ($status -eq 404) {
        Write-Host "Branch '$Branch' does not exist; creating it from the default branch"
        $def = (Invoke-GH GET "").default_branch
        $dref = Invoke-GH GET "/git/ref/heads/$def"
        Invoke-GH POST "/git/refs" @{ ref = "refs/heads/$Branch"; sha = $dref.object.sha } | Out-Null
    } else {
        throw
    }
    $ref = Invoke-GH GET "/git/ref/heads/$Branch"
    $headSha = $ref.object.sha
}
$commit = Invoke-GH GET "/git/commits/$headSha"
$baseTree = $commit.tree.sha
$remote = @{}
$tree = Invoke-GH GET "/git/trees/$baseTree`?recursive=1"
foreach ($e in $tree.tree) { if ($e.type -eq 'blob') { $remote[$e.path] = $e.sha } }
Write-Host "Head $($headSha.Substring(0,7)), $($remote.Count) remote files"

# 2. Local files
$rootFull = (Resolve-Path $Root).Path
$entries = New-Object System.Collections.ArrayList
$seen = @{}
$uploaded = 0
Get-ChildItem -Path $rootFull -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
    if (Test-Ignored $rel) { return }
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    $sha = Get-GitBlobSha $bytes
    $seen[$rel] = $true
    if ($remote.ContainsKey($rel) -and $remote[$rel] -eq $sha) { return }
    $blob = Invoke-GH POST "/git/blobs" @{ content = [Convert]::ToBase64String($bytes); encoding = 'base64' }
    if ($blob.sha -ne $sha) { Write-Warning "sha mismatch for $rel (local $sha, remote $($blob.sha))" }
    [void]$entries.Add(@{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha })
    $script:uploaded++
    Write-Host "  + $rel"
}
foreach ($p in $remote.Keys) {
    if (-not $seen.ContainsKey($p) -and -not (Test-Ignored $p)) {
        [void]$entries.Add(@{ path = $p; mode = '100644'; type = 'blob'; sha = $null })
        Write-Host "  - $p"
    }
}
if ($entries.Count -eq 0) { Write-Host "Nothing to push."; exit 0 }

# 3. Tree, commit, ref
$newTree = Invoke-GH POST "/git/trees" @{ base_tree = $baseTree; tree = $entries.ToArray() }
$newCommit = Invoke-GH POST "/git/commits" @{ message = $Message; tree = $newTree.sha; parents = @($headSha) }
Invoke-GH PATCH "/git/refs/heads/$Branch" @{ sha = $newCommit.sha; force = $false } | Out-Null
Write-Host "Pushed $($entries.Count) changes as $($newCommit.sha.Substring(0,7)): https://github.com/$Repo/commit/$($newCommit.sha)"
