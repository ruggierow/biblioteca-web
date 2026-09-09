# Abre a Biblioteca no Chrome (preferido) ou Edge sem mostrar janela de terminal.
# Chrome e preferido porque o Edge tem restricoes com a File System Access API em
# URLs file:///, impedindo que o botao "Vincular arquivo" e "Vincular fotos" funcionem.
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$html = Join-Path $dir "biblioteca.html"
# O motor fica ao lado quando distribuido, e um nivel acima aqui no repositorio.
if (-not (Test-Path $html)) { $html = Join-Path $dir "..\biblioteca.html" }

$url = "file:///" + $html.Replace("\", "/").Replace(" ", "%20")

$browsers = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
)

$aberto = $false
foreach ($browser in $browsers) {
    if (Test-Path $browser) {
        Start-Process -FilePath $browser -ArgumentList $url
        $aberto = $true
        break
    }
}

if (-not $aberto) {
    Start-Process $url   # abre com o navegador padrao do sistema
}
