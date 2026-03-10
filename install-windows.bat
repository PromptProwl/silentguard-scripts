@echo off
REM =============================================================================
REM SilentGuard Engine — Windows Installer
REM Downloads the packaged binary from a private GitHub Releases repo,
REM verifies it, downloads ONNX + PII models from HuggingFace,
REM sets up application directory layout, and writes the Chrome Native
REM Messaging Host manifest + registry key.
REM =============================================================================

setlocal EnableDelayedExpansion

REM ─── Configuration ─────────────────────────────────────────────────────────
set "VERSION=v0.1.0"
set "GITHUB_REPO=PromptProwl/silentguard-releases"

REM Repo is public, so no PAT is needed

set "BINARY_NAME=silentguard-engine-windows.exe"
set "ASSET_URL=https://api.github.com/repos/%GITHUB_REPO%/releases/tags/%VERSION%"

REM Chrome extension ID that will talk to this host
set "CHROME_EXTENSION_ID=cmhlaimhneoganidnfcodmplhfeoball"

REM Hugging Face model coordinates
set "EMBEDDING_REPO=gpahal/bge-m3-onnx-int8"
set "EMBEDDING_FILE=model_quantized.onnx"

set "PII_REPO=teimurjan/tanaos-text-anonymizer-onnx"
set "PII_FILE=onnx\model_quantized.onnx"
set "PII_FILE_URL=onnx/model_quantized.onnx"

REM ─── Windows paths (mirrors engine/config.py) ─────────────────────────────
if defined LOCALAPPDATA (
    set "LOCAL=%LOCALAPPDATA%"
) else (
    set "LOCAL=%USERPROFILE%\AppData\Local"
)
if defined APPDATA (
    set "ROAMING=%APPDATA%"
) else (
    set "ROAMING=%USERPROFILE%\AppData\Roaming"
)

set "BASE=%LOCAL%\silentguard"
set "MODELS_DIR=%BASE%\models"
set "DB_DIR=%BASE%\state\db"
set "CACHE_DIR=%BASE%\cache"
set "LOGS_DIR=%BASE%\state\logs"
set "CONFIG_DIR=%ROAMING%\silentguard"
set "APP_DIR=%BASE%\app\current"
set "BIN_DIR=%BASE%\bin"

REM ─── Pre-flight checks ────────────────────────────────────────────────────
where curl >nul 2>&1 || (
    echo [ERROR] curl is required but not found. Please install curl.
    exit /b 1
)
where certutil >nul 2>&1 || (
    echo [ERROR] certutil is required but not found.
    exit /b 1
)

echo.
echo ============================================================
echo   SilentGuard Engine Installer — Windows (%VERSION%)
echo ============================================================
echo.

REM ─── Step 1: Create directory structure ────────────────────────────────────
echo [*] Creating application directories...
for %%D in ("%MODELS_DIR%" "%DB_DIR%" "%CACHE_DIR%" "%LOGS_DIR%" "%CONFIG_DIR%" "%APP_DIR%" "%BIN_DIR%") do (
    echo     Creating %%~D
    if not exist "%%~D" mkdir "%%~D"
)
echo [OK] Directory structure created.
echo.

REM ─── Step 2: Download the binary package from GitHub Releases ──────────────
echo [*] Fetching release metadata for %VERSION% from %GITHUB_REPO%...

set "RELEASE_FILE=%CACHE_DIR%\release.json"
curl -sSL -H "Accept: application/vnd.github+json" "%ASSET_URL%" -o "%RELEASE_FILE%"

REM Extract download URL using PowerShell (avoids jq dependency on Windows)
for /f "usebackq delims=" %%U in (`powershell -NoProfile -Command ^
    "$json = Get-Content '%RELEASE_FILE%' -Raw | ConvertFrom-Json; ^
     $asset = $json.assets | Where-Object { $_.name -eq '%BINARY_NAME%' }; ^
     if ($asset) { $asset.url } else { '' }"`) do set "DOWNLOAD_URL=%%U"

if "%DOWNLOAD_URL%"=="" (
    echo [ERROR] Binary '%BINARY_NAME%' not found in release %VERSION%.
    exit /b 1
)

echo [*] Downloading %BINARY_NAME%...
set "DOWNLOAD_DEST=%CACHE_DIR%\%BINARY_NAME%"
curl -SL --progress-bar -H "Accept: application/octet-stream" "%DOWNLOAD_URL%" -o "%DOWNLOAD_DEST%"
echo [OK] Download complete: %DOWNLOAD_DEST%
echo.

REM ─── Step 3: Verify SHA-256 checksum ──────────────────────────────────────
echo [*] Computing SHA-256 checksum...

REM Try to fetch .sha256 file from release
for /f "usebackq delims=" %%U in (`powershell -NoProfile -Command ^
    "$json = Get-Content '%RELEASE_FILE%' -Raw | ConvertFrom-Json; ^
     $asset = $json.assets | Where-Object { $_.name -eq '%BINARY_NAME%.sha256' }; ^
     if ($asset) { $asset.url } else { '' }"`) do set "CHECKSUM_URL=%%U"

if not "%CHECKSUM_URL%"=="" (
    echo [*] Verifying SHA-256 checksum against release asset...
    set "CHECKSUM_FILE=%CACHE_DIR%\%BINARY_NAME%.sha256"
    curl -sSL -H "Accept: application/octet-stream" "%CHECKSUM_URL%" -o "!CHECKSUM_FILE!"

    for /f "usebackq tokens=1" %%H in ("!CHECKSUM_FILE!") do set "EXPECTED_HASH=%%H"

    for /f "tokens=*" %%H in ('certutil -hashfile "%DOWNLOAD_DEST%" SHA256 ^| findstr /v "hash CertUtil"') do set "ACTUAL_HASH=%%H"
    set "ACTUAL_HASH=!ACTUAL_HASH: =!"

    if /i "!EXPECTED_HASH!" neq "!ACTUAL_HASH!" (
        echo [ERROR] Checksum mismatch!
        echo   Expected: !EXPECTED_HASH!
        echo   Actual:   !ACTUAL_HASH!
        exit /b 1
    )
    echo [OK] SHA-256 checksum verified.
) else (
    echo [*] No .sha256 asset found — computing checksum for reference:
    certutil -hashfile "%DOWNLOAD_DEST%" SHA256
)
echo.

REM ─── Step 4: Install binary ───────────────────────────────────────────────
echo [*] Installing binary to %APP_DIR%...
copy /Y "%DOWNLOAD_DEST%" "%APP_DIR%\%BINARY_NAME%" >nul
copy /Y "%APP_DIR%\%BINARY_NAME%" "%BIN_DIR%\silentguard-engine.exe" >nul
echo [OK] Binary installed: %APP_DIR%\%BINARY_NAME%
echo [OK] Copy created:     %BIN_DIR%\silentguard-engine.exe
echo.

REM ─── Step 5: Write Chrome Native Messaging Host manifest + registry ───────
echo [*] Writing Chrome Native Messaging Host manifest and registry key...

set "NMH_PATH=%CONFIG_DIR%\ai.silentguard.host.json"
set "BINARY_PATH_ESCAPED=%APP_DIR%\%BINARY_NAME%"

REM Write the JSON manifest using PowerShell for proper JSON formatting
powershell -NoProfile -Command ^
    "$json = @{" ^
    "  name = 'ai.silentguard.host';" ^
    "  description = 'SilentGuard Engine - local AI inference for browser privacy';" ^
    "  path = '%BINARY_PATH_ESCAPED%'.Replace('\','\\');" ^
    "  type = 'stdio';" ^
    "  allowed_origins = @('chrome-extension://%CHROME_EXTENSION_ID%/')" ^
    "};" ^
    "$json | ConvertTo-Json | Set-Content '%NMH_PATH%'"

echo     Wrote %NMH_PATH%

REM Register with Chrome via registry (HKCU — no admin needed)
reg add "HKCU\Software\Google\Chrome\NativeMessagingHosts\ai.silentguard.host" /ve /t REG_SZ /d "%NMH_PATH%" /f >nul 2>&1
echo     Registered Chrome NativeMessagingHost in HKCU registry.

REM Also register for Chromium-based Edge
reg add "HKCU\Software\Microsoft\Edge\NativeMessagingHosts\ai.silentguard.host" /ve /t REG_SZ /d "%NMH_PATH%" /f >nul 2>&1
echo     Registered Edge NativeMessagingHost in HKCU registry.

echo [OK] Chrome Native Messaging Host manifest installed.
echo.

REM ─── Step 6: Download models from Hugging Face ────────────────────────────
echo [*] Downloading ONNX embedding model from Hugging Face...
echo     Repository: %EMBEDDING_REPO%
echo     File:       %EMBEDDING_FILE%

set "EMBEDDING_MODEL_DIR=%MODELS_DIR%\%EMBEDDING_REPO:/=\%"
if not exist "%EMBEDDING_MODEL_DIR%" mkdir "%EMBEDDING_MODEL_DIR%"

curl -SL --progress-bar "https://huggingface.co/%EMBEDDING_REPO%/resolve/main/%EMBEDDING_FILE%" -o "%EMBEDDING_MODEL_DIR%\%EMBEDDING_FILE%"
echo [OK] Embedding model downloaded: %EMBEDDING_MODEL_DIR%\%EMBEDDING_FILE%

echo [*] Downloading tokenizer files for embedding model...
for %%F in (tokenizer.json tokenizer_config.json special_tokens_map.json config.json) do (
    curl -sL -o "%EMBEDDING_MODEL_DIR%\%%F" -w "%%{http_code}" "https://huggingface.co/%EMBEDDING_REPO%/resolve/main/%%F" > "%CACHE_DIR%\http_status.tmp" 2>nul
    set /p HTTP_STATUS=<"%CACHE_DIR%\http_status.tmp"
    if "!HTTP_STATUS!"=="200" (
        echo     Downloaded %%F
    ) else (
        echo     Skipped %%F ^(not found^)
        del /q "%EMBEDDING_MODEL_DIR%\%%F" 2>nul
    )
)
echo.

echo [*] Downloading PII detection model from Hugging Face...
echo     Repository: %PII_REPO%
echo     File:       %PII_FILE%

set "PII_MODEL_DIR=%MODELS_DIR%\%PII_REPO:/=\%"
if not exist "%PII_MODEL_DIR%\onnx" mkdir "%PII_MODEL_DIR%\onnx"

curl -SL --progress-bar "https://huggingface.co/%PII_REPO%/resolve/main/%PII_FILE_URL%" -o "%PII_MODEL_DIR%\%PII_FILE%"
echo [OK] PII model downloaded: %PII_MODEL_DIR%\%PII_FILE%

echo [*] Downloading tokenizer files for PII model...
for %%F in (tokenizer.json tokenizer_config.json special_tokens_map.json config.json vocab.txt) do (
    curl -sL -o "%PII_MODEL_DIR%\%%F" -w "%%{http_code}" "https://huggingface.co/%PII_REPO%/resolve/main/%%F" > "%CACHE_DIR%\http_status.tmp" 2>nul
    set /p HTTP_STATUS=<"%CACHE_DIR%\http_status.tmp"
    if "!HTTP_STATUS!"=="200" (
        echo     Downloaded %%F
    ) else (
        echo     Skipped %%F ^(not found^)
        del /q "%PII_MODEL_DIR%\%%F" 2>nul
    )
)
del /q "%CACHE_DIR%\http_status.tmp" 2>nul
echo.

REM ─── Done ──────────────────────────────────────────────────────────────────
echo.
echo ============================================================
echo   SilentGuard Engine installed successfully!
echo ============================================================
echo.
echo   Binary:      %APP_DIR%\%BINARY_NAME%
echo   Copy:        %BIN_DIR%\silentguard-engine.exe
echo   Models:      %MODELS_DIR%\
echo   Database:    %DB_DIR%\
echo   Logs:        %LOGS_DIR%\
echo   Config:      %CONFIG_DIR%\
echo   Cache:       %CACHE_DIR%\
echo.
echo   To start the engine:
echo     "%BIN_DIR%\silentguard-engine.exe"
echo.

endlocal
