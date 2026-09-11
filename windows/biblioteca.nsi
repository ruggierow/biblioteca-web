; Instalador do Biblioteca para Windows
;
; A partir da v1.8.3 este instalador empacota o APP NATIVO (Tauri) e nao mais o
; HTML aberto no navegador. A diferenca que importa para o usuario: o app acha
; sozinho o biblioteca.txt no iCloud Drive, sem vincular arquivo a mao e sem a
; permissao do navegador caducando a cada reinicio.
;
; O HTML nao e mais instalado a parte — ele vai embutido dentro do executavel.
;
; Uso: makensis biblioteca.nsi
;      (rodar nesta pasta, com biblioteca-tauri.exe copiado para ca)

Unicode True
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define APP_NAME        "Biblioteca"
!define APP_VERSION     "1.8.3"
!define APP_PUBLISHER   "Wilson"
!define APP_ICON        "biblioteca.ico"
!define APP_EXE         "Biblioteca.exe"
!define INSTALL_DIR     "$LOCALAPPDATA\Biblioteca"
!define REG_KEY         "Software\${APP_NAME}"
!define UNINSTALL_KEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"

Name "${APP_NAME} ${APP_VERSION}"
OutFile "Biblioteca-${APP_VERSION}-setup.exe"
InstallDir "${INSTALL_DIR}"
InstallDirRegKey HKCU "${REG_KEY}" "InstallDir"
RequestExecutionLevel user
ShowInstDetails show
ShowUnInstDetails show

!define MUI_ICON        "${APP_ICON}"
!define MUI_UNICON      "${APP_ICON}"
!define MUI_WELCOMEFINISHPAGE_BITMAP_NOSTRETCH
!define MUI_FINISHPAGE_RUN          "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT     "Abrir a Biblioteca agora"
!define MUI_FINISHPAGE_SHOWREADME   ""

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "PortugueseBR"

; ---------------------------------------------------------------
; O app desenha a interface com o WebView2 (o motor do Edge). Vem de fabrica no
; Windows 11, mas conferimos: sem ele a janela abriria em branco, e um aviso
; claro na instalacao poupa um diagnostico dificil depois.
; ---------------------------------------------------------------
Function VerificarWebView2
    ReadRegStr $0 HKLM \
        "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
    ${If} $0 == ""
        ReadRegStr $0 HKLM \
            "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
    ${EndIf}
    ${If} $0 == ""
        ReadRegStr $0 HKCU \
            "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
    ${EndIf}
    ${If} $0 == ""
        MessageBox MB_ICONEXCLAMATION|MB_OK \
            "O WebView2 nao foi encontrado neste computador.$\r$\n$\r$\n\
             A Biblioteca precisa dele para desenhar a janela. Instale o$\r$\n\
             'Microsoft Edge WebView2 Runtime' e execute este instalador de novo."
    ${EndIf}
FunctionEnd

Function .onInit
    Call VerificarWebView2
FunctionEnd

; ---------------------------------------------------------------
Section "-Principal" SecMain
    SetOutPath "$INSTDIR"

    ; Restos da versao anterior, que rodava o HTML no navegador. Sem isto o
    ; usuario ficaria com dois caminhos possiveis para abrir o programa — e o
    ; antigo continuaria pedindo para vincular o arquivo a mao.
    Delete "$INSTDIR\biblioteca.html"
    Delete "$INSTDIR\Abrir Biblioteca.ps1"
    Delete "$INSTDIR\Abrir Biblioteca.vbs"
    Delete "$INSTDIR\Abrir Biblioteca.bat"
    Delete "$INSTDIR\Biblioteca.vbs"
    Delete "$INSTDIR\servidor.ps1"
    Delete "$INSTDIR\index.html"
    Delete "$INSTDIR\manifest.json"
    Delete "$INSTDIR\sw.js"
    Delete "$INSTDIR\icon.ico"
    RMDir /r "$INSTDIR\icons"
    Delete "$DESKTOP\Abrir Biblioteca.lnk"

    ; O app nativo. O nome do arquivo compilado e biblioteca-tauri.exe;
    ; instalamos como Biblioteca.exe, que e o que aparece no Gerenciador
    ; de Tarefas e nos atalhos.
    File /oname=${APP_EXE} "biblioteca-tauri.exe"

    File "biblioteca.ico"
    File "Manual.html"
    File "Manual.pdf"

    ; Menu Iniciar
    CreateDirectory "$SMPROGRAMS\${APP_NAME}"
    CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" \
        "$INSTDIR\${APP_EXE}" "" \
        "$INSTDIR\biblioteca.ico" 0

    CreateShortCut "$SMPROGRAMS\${APP_NAME}\Manual.lnk" \
        "$INSTDIR\Manual.pdf" "" "" 0 \
        SW_SHOWNORMAL "" "Manual do Biblioteca"

    ; Atalho no Desktop
    CreateShortCut "$DESKTOP\Biblioteca.lnk" \
        "$INSTDIR\${APP_EXE}" "" \
        "$INSTDIR\biblioteca.ico" 0 \
        SW_SHOWNORMAL "" "Biblioteca — Gestão de livros"

    ; Desinstalador
    WriteUninstaller "$INSTDIR\Desinstalar Biblioteca.exe"

    ; Registro (Adicionar/Remover Programas)
    WriteRegStr   HKCU "${REG_KEY}" "InstallDir" "$INSTDIR"
    WriteRegStr   HKCU "${UNINSTALL_KEY}" "DisplayName"          "${APP_NAME} ${APP_VERSION}"
    WriteRegStr   HKCU "${UNINSTALL_KEY}" "DisplayVersion"       "${APP_VERSION}"
    WriteRegStr   HKCU "${UNINSTALL_KEY}" "Publisher"            "${APP_PUBLISHER}"
    WriteRegStr   HKCU "${UNINSTALL_KEY}" "InstallLocation"      "$INSTDIR"
    WriteRegStr   HKCU "${UNINSTALL_KEY}" "UninstallString"      '"$INSTDIR\Desinstalar Biblioteca.exe"'
    WriteRegStr   HKCU "${UNINSTALL_KEY}" "DisplayIcon"          "$INSTDIR\biblioteca.ico"
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify"             1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair"             1

    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" "$0"
SectionEnd

; ---------------------------------------------------------------
Section "Uninstall"
    ; O app precisa estar fechado para o executavel poder ser apagado.
    ${If} ${FileExists} "$INSTDIR\${APP_EXE}"
        ExecWait 'taskkill /IM "${APP_EXE}" /F' $0
    ${EndIf}

    Delete "$INSTDIR\${APP_EXE}"
    Delete "$INSTDIR\biblioteca.ico"
    Delete "$INSTDIR\Manual.html"
    Delete "$INSTDIR\Manual.pdf"
    Delete "$INSTDIR\Desinstalar Biblioteca.exe"

    ; Restos possiveis da versao que rodava no navegador
    Delete "$INSTDIR\biblioteca.html"
    Delete "$INSTDIR\Abrir Biblioteca.ps1"
    Delete "$INSTDIR\Abrir Biblioteca.vbs"
    Delete "$INSTDIR\Abrir Biblioteca.bat"

    RMDir  "$INSTDIR"

    Delete "$DESKTOP\Biblioteca.lnk"
    Delete "$DESKTOP\Abrir Biblioteca.lnk"
    Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
    Delete "$SMPROGRAMS\${APP_NAME}\Manual.lnk"
    RMDir  "$SMPROGRAMS\${APP_NAME}"

    DeleteRegKey HKCU "${REG_KEY}"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"

    ; A base de livros e as fotos ficam no iCloud Drive e NAO sao apagadas.
SectionEnd
