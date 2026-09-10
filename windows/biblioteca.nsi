; Instalador do Biblioteca para Windows
; Gerado pelo makensis no Mac. Empacota o motor web (HTML + scripts).
; Uso: makensis biblioteca.nsi
;      (rodar na pasta motor-web/windows/, com biblioteca.html copiado aqui)

Unicode True
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "FileFunc.nsh"

!define APP_NAME        "Biblioteca"
!define APP_VERSION     "1.8.3"
!define APP_PUBLISHER   "Wilson"
!define APP_ICON        "biblioteca.ico"
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
!define MUI_FINISHPAGE_RUN          "$INSTDIR\Abrir Biblioteca.vbs"
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
Section "-Principal" SecMain
    SetOutPath "$INSTDIR"

    File "biblioteca.html"
    File "Abrir Biblioteca.ps1"
    File "Abrir Biblioteca.vbs"
    File "Abrir Biblioteca.bat"
    File "biblioteca.ico"
    File "Manual.html"
    File "Manual.pdf"

    ; Atalho para o manual no Menu Iniciar
    CreateShortCut "$SMPROGRAMS\${APP_NAME}\Manual.lnk" \
        "$INSTDIR\Manual.pdf" "" "" 0 \
        SW_SHOWNORMAL "" "Manual do Biblioteca"

    ; Atalho no Desktop
    CreateShortCut "$DESKTOP\Biblioteca.lnk" \
        "$INSTDIR\Abrir Biblioteca.vbs" "" \
        "$INSTDIR\biblioteca.ico" 0 \
        SW_SHOWNORMAL "" "Biblioteca — Gestão de livros"

    ; Menu Iniciar
    CreateDirectory "$SMPROGRAMS\${APP_NAME}"
    CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" \
        "$INSTDIR\Abrir Biblioteca.vbs" "" \
        "$INSTDIR\biblioteca.ico" 0

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
    Delete "$INSTDIR\biblioteca.html"
    Delete "$INSTDIR\Abrir Biblioteca.ps1"
    Delete "$INSTDIR\Abrir Biblioteca.vbs"
    Delete "$INSTDIR\Abrir Biblioteca.bat"
    Delete "$INSTDIR\biblioteca.ico"
    Delete "$INSTDIR\Manual.html"
    Delete "$INSTDIR\Manual.pdf"
    Delete "$INSTDIR\Desinstalar Biblioteca.exe"
    RMDir  "$INSTDIR"

    Delete "$DESKTOP\Biblioteca.lnk"
    Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
    Delete "$SMPROGRAMS\${APP_NAME}\Manual.lnk"
    RMDir  "$SMPROGRAMS\${APP_NAME}"

    DeleteRegKey HKCU "${REG_KEY}"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
