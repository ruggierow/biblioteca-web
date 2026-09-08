# Abre a Biblioteca no Chrome ou Edge sem mostrar janela de terminal
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$html = Join-Path $dir "biblioteca.html"
# O motor fica ao lado quando distribuido, e um nivel acima aqui no repositorio.
if (-not (Test-Path $html)) { $html = Join-Path $dir "..\biblioteca.html" }

$browsers = @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)

$aberto = $false
foreach ($browser in $browsers) {
    if (Test-Path $browser) {
        Start-Process $browser $html
        $aberto = $true
        break
    }
}

if (-not $aberto) {
    Start-Process $html   # abre com o navegador padrao do sistema
}
