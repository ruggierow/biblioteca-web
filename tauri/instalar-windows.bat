@echo off
setlocal enabledelayedexpansion
echo === Biblioteca Windows - Instalacao e Build ===
echo.

REM Verifica cargo primeiro (pode ja estar no PATH com ambiente correto)
cargo --version >nul 2>&1
if not errorlevel 1 (
    echo Rust encontrado:
    cargo --version
    goto :build
)

REM Cargo nao esta no PATH — tenta configurar o ambiente do Visual Studio
echo Configurando ambiente Visual Studio...
set VCVARS=
for %%E in (Enterprise Professional Community BuildTools) do (
    for %%Y in (2022 2019 2017) do (
        set T="C:\Program Files\Microsoft Visual Studio\%%Y\%%E\VC\Auxiliary\Build\vcvarsall.bat"
        if exist !T! ( set VCVARS=!T! & goto :achou )
        set T="C:\Program Files (x86)\Microsoft Visual Studio\%%Y\%%E\VC\Auxiliary\Build\vcvarsall.bat"
        if exist !T! ( set VCVARS=!T! & goto :achou )
    )
)

:achou
if "%VCVARS%"=="" (
    echo.
    echo ERRO: Compilador C++ nao encontrado.
    echo.
    echo Instale o Visual Studio Build Tools com este comando no PowerShell:
    echo   winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive"
    echo.
    echo Depois feche esta janela e rode instalar-windows.bat novamente.
    pause
    exit /b 1
)

call %VCVARS% x64 >nul 2>&1

cargo --version >nul 2>&1
if errorlevel 1 (
    echo ERRO: Rust/Cargo nao encontrado.
    echo Instale em: https://rustup.rs
    pause
    exit /b 1
)

echo Rust encontrado:
cargo --version

:build
REM Instala tauri-cli se necessario
cargo tauri --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo Instalando tauri-cli (pode demorar 10-15 minutos)...
    cargo install tauri-cli --version "^2"
    if errorlevel 1 (
        echo ERRO: Falha ao instalar tauri-cli.
        pause
        exit /b 1
    )
)

echo tauri-cli pronto:
cargo tauri --version

REM Compila o app
echo.
echo Compilando Biblioteca para Windows...
echo (primeira vez: 15-20 minutos; proximas vezes: 2-3 minutos)
cd /d "%~dp0src-tauri"
cargo tauri build

if errorlevel 1 (
    echo.
    echo ERRO: Falha na compilacao. Veja as mensagens acima.
    pause
    exit /b 1
)

echo.
echo === Pronto! ===
echo O instalador foi gerado em:
echo   %~dp0src-tauri\target\release\bundle\msi\
echo.
echo Execute o arquivo .msi para instalar o Biblioteca no Windows.
pause
