# Cria (ou atualiza) o atalho "Biblioteca" no Desktop do Windows.
# Aponta para Abrir Biblioteca.vbs na mesma pasta, com icone biblioteca.ico.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$shell  = New-Object -ComObject WScript.Shell
$atalho = $shell.CreateShortcut("$env:USERPROFILE\Desktop\Biblioteca.lnk")
$atalho.TargetPath      = Join-Path $dir "Abrir Biblioteca.vbs"
$atalho.WorkingDirectory = $dir
$icone = Join-Path $dir "biblioteca.ico"
if (Test-Path $icone) { $atalho.IconLocation = $icone }
$atalho.Description = "Biblioteca — Sistema de Gestao"
$atalho.Save()

[System.Windows.Forms.MessageBox]::Show(
    "Atalho criado no Desktop!`nClique em OK e depois abra pelo icone Biblioteca.",
    "Biblioteca instalada",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null
