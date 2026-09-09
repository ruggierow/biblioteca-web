@echo off
setlocal enabledelayedexpansion
echo === Biblioteca Windows - Instalacao e Build ===
echo.

REM Localiza o vcvarsall.bat do Visual Studio (2019 ou 2022, qualquer edicao)
set VCVARS=
for %%E in (Enterprise Professional Community BuildTools) do (
    for %%Y in (2022 2019) do (
        set TENTATIVA="C:\Program Files\Microsoft Visual Studio\%%Y\%%E\VC\Auxiliary\Build\vcvarsall.bat"
        if exist !TENTATIVA! ( set VCVARS=!TENTATIVA! & goto :achou )
        set TENTATIVA="C:\Program Files (x86)\Microsoft Visual Studio\%%Y\%%E\VC\Auxiliary\Build\vcvarsall.bat"
        if exist !TENTATIVA! ( set VCVARS=!TENTATIVA! & goto :achou )
    )
)

:achou
if "%VCVARS%"=="" (
    echo ERRO: Visual Studio nao encontrado. Instale o "Desktop development with C++".
    pause
    exit /b 1
)

echo Configurando ambiente Visual Studio...
call %VCVARS% x64 >nul 2>&1

REM Verifica cargo
cargo --version >nul 2>&1
if errorlevel 1 (
    echo ERRO: Rust/Cargo nao encontrado. Instale em https://rustup.rs e tente novamente.
    pause
    exit /b 1
)

echo Rust encontrado:
cargo --version

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

echo tauri-cli encontrado:
cargo tauri --version

REM Compila o app
echo.
echo Compilando Biblioteca para Windows (primeira vez: 15-20 minutos)...
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
echo Instalador gerado em:
echo   motor-web\tauri\src-tauri\target\release\bundle\
pause
