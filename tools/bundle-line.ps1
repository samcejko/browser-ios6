param(
    [Parameter(Mandatory = $true)][int]$Line,
    # a package run folder (packages\run-<id>) or a .deb; the newest run when left out
    [string]$Package = '',
    # the bundle's name from the error (__br_polyfills-<crc>.js), to check that the build is the one that reported it
    [string]$Crc = '',
    [int]$Context = 0
)
# Shows the line of the page polyfill bundle (__br_polyfills-<crc>.js) that an error on the device names: the bundle is
# put together the way BRCSSRewriter polyfillBundle does it, from the minified js/ copies in the .deb, with and without
# the BRDebugJSErrors line in front. iOS 6 reports a line and no column.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Package) { $Package = (Get-ChildItem (Join-Path $root 'packages') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
$deb = $Package
if ((Get-Item $Package).PSIsContainer) { $deb = (Get-ChildItem $Package -Filter *.deb | Select-Object -First 1).FullName }
$work = Join-Path $env:TEMP ('bundle-line-' + [IO.Path]::GetFileNameWithoutExtension($deb) + '-' + (Get-Item $deb).LastWriteTime.Ticks)
if (-not (Test-Path (Join-Path $work 'Applications'))) {
    New-Item -ItemType Directory -Force $work | Out-Null
    # (a .deb is an ar archive: data.tar.* holds the app)
    $b = [IO.File]::ReadAllBytes($deb)
    $pos = 8
    while ($pos -lt $b.Length) {
        $name = [Text.Encoding]::ASCII.GetString($b, $pos, 16).Trim().TrimEnd('/')
        $size = [int]([Text.Encoding]::ASCII.GetString($b, $pos + 48, 10).Trim())
        if ($name -like 'data.tar*') {
            $tarPath = Join-Path $work $name
            $fs = [IO.File]::Create($tarPath); $fs.Write($b, $pos + 60, $size); $fs.Close()
            Push-Location $work; tar -xf $tarPath; Pop-Location
        }
        $pos += 60 + $size
        if ($size % 2) { $pos++ }
    }
}
$app = Get-ChildItem $work -Recurse -Directory -Filter '*.app' | Select-Object -First 1
if (-not $app) { throw "no app in $deb" }
Add-Type -TypeDefinition @'
public static class BundleLineCrc { public static uint Compute(byte[] b){ uint[] t=new uint[256]; for(uint i=0;i<256;i++){ uint c=i; for(int k=0;k<8;k++) c=(c&1)!=0?0xEDB88320u^(c>>1):c>>1; t[i]=c;} uint crc=0xFFFFFFFFu; foreach(byte x in b) crc=t[(crc^x)&0xFF]^(crc>>8); return crc^0xFFFFFFFFu; } }
'@ -ErrorAction SilentlyContinue
# (the order of BRCSSRewriter polyfillBundle)
$names = 'page-prelude', 'core-js-custom', 'regenerator-runtime', 'jsfix-helpers', 'fetch', 'intersection-observer', 'resize-observer',
    'picturefill', 'dialog-polyfill', 'object-fit-images', 'shims', 'regexp-shim', 'shims-extra'
$utf8 = New-Object Text.UTF8Encoding($false)
$matched = $false
foreach ($debug in $false, $true) {
    $ms = New-Object IO.MemoryStream
    $put = { param($s) $x = $utf8.GetBytes($s); $ms.Write($x, 0, $x.Length) }
    if ($debug) { & $put "window.__brDebugErrors=true;`n" }
    foreach ($n in $names) {
        $p = Join-Path $app.FullName "js\$n.js"
        if (-not (Test-Path $p)) { $p = Join-Path $app.FullName "$n.js" }
        if (-not (Test-Path $p)) { continue }
        & $put "`n;/* $n */`n"
        $x = [IO.File]::ReadAllBytes($p); $ms.Write($x, 0, $x.Length)
        & $put "`n;`n"
    }
    $bytes = $ms.ToArray()
    $crcHex = '{0:x8}' -f [BundleLineCrc]::Compute($bytes)
    if ($Crc -and $crcHex -ne $Crc.ToLower()) { continue }
    $matched = $true
    # (JavaScriptCore counts CR LF as one line, and CR, LS and PS as line ends too)
    $text = $utf8.GetString($bytes) -replace "`r`n", "`n" -replace "[`r  ]", "`n"
    $lines = $text -split "`n"
    $part = ''; $partLine = 0
    for ($k = 0; $k -lt [Math]::Min($Line, $lines.Count); $k++) { if ($lines[$k] -match '^;/\* (.+) \*/$') { $part = $matches[1]; $partLine = $k + 1 } }
    "__br_polyfills-$crcHex.js" + $(if ($debug) { ' (BRDebugJSErrors on)' } else { '' }) + ": line $Line of $($lines.Count), in $part (line $($Line - $partLine) of it)"
    for ($k = [Math]::Max(1, $Line - $Context); $k -le [Math]::Min($lines.Count, $Line + $Context); $k++) {
        $t = $lines[$k - 1]
        '{0,6}{1} {2}' -f $k, $(if ($k -eq $Line) { '>' } else { ':' }), $(if ($t.Length -gt 1200) { $t.Substring(0, 1200) + ' ...(' + $t.Length + ' chars)' } else { $t })
    }
    ''
}
if ($Crc -and -not $matched) { "no bundle $Crc in ${deb}: another build, or a swapped shim was on the device" }
