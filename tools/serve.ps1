# Tiny static file server for local testing (e.g. tools/cssfix-test.html in a browser).
# Usage: .\tools\serve.ps1 [-Port 8123] [-Root <project root>]
param([int]$Port = 8123, [string]$Root = '')
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path $Root).Path
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $Root at http://localhost:$Port/ (Ctrl+C to stop)"
$types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json'; '.txt' = 'text/plain; charset=utf-8'; '.png' = 'image/png' }
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/') -replace '/', '\'
    $path = Join-Path $Root $rel
    try {
        if ((Test-Path $path -PathType Leaf) -and $path.StartsWith($Root)) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $ext = [IO.Path]::GetExtension($path).ToLower()
            $ctx.Response.ContentType = if ($types[$ext]) { $types[$ext] } else { 'application/octet-stream' }
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $ctx.Response.StatusCode = 404
        }
    } catch {
        $ctx.Response.StatusCode = 500
    }
    $ctx.Response.Close()
}
