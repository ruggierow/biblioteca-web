param([string]$dir, [int]$port = 49152)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch { exit 0 }

$mimes = @{
    ".html" = "text/html; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png"  = "image/png"
    ".ico"  = "image/x-icon"
    ".webp" = "image/webp"
}

while ($listener.IsListening) {
    try {
        $ctx  = $listener.GetContext()
        $lp   = $ctx.Request.Url.LocalPath.TrimStart("/")
        if (-not $lp) { $lp = "index.html" }
        $file = Join-Path $dir $lp
        if (Test-Path $file -PathType Leaf) {
            $ext = [IO.Path]::GetExtension($file).ToLower()
            $ctx.Response.ContentType = if ($mimes[$ext]) { $mimes[$ext] } else { "application/octet-stream" }
            $b = [IO.File]::ReadAllBytes($file)
            $ctx.Response.ContentLength64 = $b.Length
            $ctx.Response.OutputStream.Write($b, 0, $b.Length)
        } else {
            $ctx.Response.StatusCode = 404
            $ctx.Response.ContentLength64 = 0
        }
        $ctx.Response.Close()
    } catch { }
}
