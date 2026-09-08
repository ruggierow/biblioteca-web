' Abre a Biblioteca no navegador sem exibir janela de terminal
Dim shell, fso, pasta, html, q
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")
q = Chr(34)

pasta = fso.GetParentFolderName(WScript.ScriptFullName)
html  = pasta & "\biblioteca.html"
' O motor fica ao lado quando distribuido, e um nivel acima aqui no repositorio.
If Not fso.FileExists(html) Then html = pasta & "\..\biblioteca.html"

' Todos os caminhos possiveis de Edge e Chrome no Windows
Dim browsers(4)
browsers(0) = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
browsers(1) = "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
browsers(2) = "C:\Program Files\Google\Chrome\Application\chrome.exe"
browsers(3) = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
browsers(4) = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Google\Chrome\Application\chrome.exe"

Dim i, found
found = False
For i = 0 To 4
    If fso.FileExists(browsers(i)) Then
        shell.Run q & browsers(i) & q & " " & q & html & q, 1, False
        found = True
        Exit For
    End If
Next

' Fallback: cmd oculto + start — abre com navegador padrao sem mostrar terminal
If Not found Then
    shell.Run "cmd /c start " & q & q & " " & q & html & q, 0, False
End If
