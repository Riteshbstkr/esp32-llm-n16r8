<#
.SYNOPSIS
  Build and flash the TinyStories LLM (stories260K) onto an ESP32-S3 N16R8 board.

.DESCRIPTION
  1. Checks that Git and Python are installed.
  2. Downloads ESP-IDF (one time) and installs the ESP32-S3 toolchain (one time).
  3. Configures the project (16 MB flash, 8 MB octal PSRAM) and builds it.
  4. Flashes the firmware AND the model (the SPIFFS "data" partition).
  5. Opens the serial monitor so you can watch the story being generated.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\flash.ps1
  powershell -ExecutionPolicy Bypass -File .\flash.ps1 -Port COM5
  powershell -ExecutionPolicy Bypass -File .\flash.ps1 -Reconfigure   # rebuild config from scratch
#>
[CmdletBinding()]
param(
    [string]$Port,                       # e.g. COM5. If omitted, it is auto-detected / asked.
    [string]$IdfVersion = "v5.3.6",      # the project was written against IDF 5.3.x
    [string]$IdfRoot,                    # default: C:\esp\esp-idf-<version>
    [int]$Baud = 460800,                 # flashing speed; lower it (115200) if flashing is flaky
    [switch]$Reconfigure,                # delete sdkconfig + build folder and start clean
    [switch]$NoMonitor                   # flash only, do not open the serial monitor
)

$ErrorActionPreference = "Stop"
$ProjectDir = $PSScriptRoot
if (-not $IdfRoot) { $IdfRoot = "C:\esp\esp-idf-$IdfVersion" }

function Write-Step([string]$Message) { Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "WARNING: $Message" -ForegroundColor Yellow }
function Stop-WithError([string]$Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# Run idf.py through the python that export.ps1 put first on PATH.
function Invoke-Idf([string[]]$IdfArgs, [string]$Hint = "") {
    & python (Join-Path $IdfRoot "tools\idf.py") @IdfArgs
    if ($LASTEXITCODE -ne 0) {
        $msg = "idf.py $($IdfArgs -join ' ') failed (exit code $LASTEXITCODE). Scroll up to the FIRST error message."
        if ($Hint) { $msg = "$msg`n$Hint" }
        Stop-WithError $msg
    }
}

# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

# A window opened before Git/Python was installed has a stale PATH. Re-read the
# machine and user PATH from Windows, then also try Git's usual install folders.
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = (@($env:Path, $machinePath, $userPath) | Where-Object { $_ }) -join ";"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $gitDirs = @(
        "$env:ProgramFiles\Git\cmd",
        "${env:ProgramFiles(x86)}\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Git\cmd"
    )
    foreach ($dir in $gitDirs) {
        if ($dir -and (Test-Path (Join-Path $dir "git.exe"))) {
            $env:Path = "$dir;$env:Path"
            Write-Host "Found Git in $dir (it was not on PATH in this window)"
            break
        }
    }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-WithError ("Git was not found. If winget says it is installed, close ALL PowerShell windows, open a new one and re-run. " +
        "If that still fails, run:  Get-ChildItem C:\ -Recurse -Filter git.exe -ErrorAction SilentlyContinue | Select-Object -First 3 FullName   and tell me what it prints.")
}

$pyVersion = ""
try { $pyVersion = (& python --version 2>&1 | Out-String).Trim() } catch { $pyVersion = "" }
if ($pyVersion -match 'Python 3\.(\d+)') {
    $pyMinor = [int]$Matches[1]
}
else {
    Stop-WithError ("Python 3 was not found (the Microsoft Store 'python' shortcut does not count). " +
        "Run:  winget install --id Python.Python.3.12 -e   then open a NEW PowerShell window and re-run this script.")
}
if ($pyMinor -lt 9) { Stop-WithError "Python 3.9 or newer is required, found: $pyVersion" }
if ($pyMinor -ge 13) {
    Write-Warn "Found $pyVersion. ESP-IDF 5.3 is best tested with Python 3.9-3.12. If the install step fails, install 3.12 (winget install --id Python.Python.3.12 -e) and re-run."
}
Write-Host "Git OK, $pyVersion OK"

if ($ProjectDir.Length -gt 60) {
    Write-Warn "This folder path is long ($($ProjectDir.Length) chars). Windows path limits can break the build. Consider moving the project to something like C:\esp\esp32-llm."
}
if ($ProjectDir -match '\s') {
    Write-Warn "This folder path contains spaces. If the build fails with odd path errors, move the project to C:\esp\esp32-llm."
}

# Let git (including the one idf.py's component manager uses) handle long Windows paths,
# for this session only - nothing is changed in your git config.
$env:GIT_CONFIG_COUNT = "2"
$env:GIT_CONFIG_KEY_0 = "core.longpaths"
$env:GIT_CONFIG_VALUE_0 = "true"
# No CRLF conversion: downloaded components are hash-checked and would be reported "corrupted" otherwise.
$env:GIT_CONFIG_KEY_1 = "core.autocrlf"
$env:GIT_CONFIG_VALUE_1 = "false"

# ---------------------------------------------------------------------------
if (-not (Test-Path (Join-Path $IdfRoot "export.ps1"))) {
    if ((Test-Path $IdfRoot) -and (Get-ChildItem $IdfRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Stop-WithError "$IdfRoot exists but is not a complete ESP-IDF download (an earlier attempt was probably interrupted). Delete that folder and re-run."
    }
    Write-Step "Downloading ESP-IDF $IdfVersion to $IdfRoot (one time, roughly 1 GB, several minutes)"
    New-Item -ItemType Directory -Force -Path (Split-Path $IdfRoot -Parent) | Out-Null
    & git clone -b $IdfVersion --depth 1 --recursive --shallow-submodules https://github.com/espressif/esp-idf.git $IdfRoot
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "git clone of ESP-IDF failed. Check your internet connection (and any proxy/VPN), delete $IdfRoot if it exists, then re-run."
    }
}

$toolsMarker = Join-Path $IdfRoot ".esp32s3_tools_installed"
if (-not (Test-Path $toolsMarker)) {
    Write-Step "Installing the ESP32-S3 compiler toolchain (one time, several minutes)"
    & (Join-Path $IdfRoot "install.ps1") esp32s3
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "ESP-IDF tool installation failed. Scroll up for the reason, fix it, and re-run (it will resume)."
    }
    New-Item -ItemType File -Path $toolsMarker | Out-Null
}

Write-Step "Activating ESP-IDF environment"
. (Join-Path $IdfRoot "export.ps1")

& python (Join-Path $IdfRoot "tools\idf.py") --version
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "The ESP-IDF environment did not activate correctly (see messages above). Delete $IdfRoot\.esp32s3_tools_installed and re-run to repeat the tool install."
}

# ---------------------------------------------------------------------------
Set-Location $ProjectDir

if ($Reconfigure) {
    Write-Step "Clean reconfigure requested: removing sdkconfig, build folder and downloaded components"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $ProjectDir "build")
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $ProjectDir "managed_components")
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $ProjectDir "sdkconfig")
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $ProjectDir "sdkconfig.old")
}

if (-not (Test-Path (Join-Path $ProjectDir "sdkconfig"))) {
    Write-Step "Configuring project for ESP32-S3 (applies sdkconfig.defaults: 16 MB flash, octal PSRAM)"
    Invoke-Idf @("set-target", "esp32s3")
}

# Make sure the generated config really is the N16R8 one (a stale sdkconfig would silently win).
$cfg = Get-Content (Join-Path $ProjectDir "sdkconfig") -Raw
$required = @('CONFIG_IDF_TARGET="esp32s3"', 'CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y', 'CONFIG_SPIRAM_MODE_OCT=y', 'CONFIG_SPIRAM_USE_MALLOC=y')
foreach ($line in $required) {
    if ($cfg -notmatch [regex]::Escape($line)) {
        Stop-WithError "sdkconfig is missing '$line' - it is left over from a different setup. Re-run with:  .\flash.ps1 -Reconfigure"
    }
}
Write-Host "sdkconfig OK (ESP32-S3, 16 MB flash, octal PSRAM)"

# ---------------------------------------------------------------------------
Write-Step "Building (first build also downloads esp-dsp and u8g2, a few minutes)"
Invoke-Idf @("build") "If it mentions a missing component or git error, check your internet connection and that 'git' works in this window."

# ---------------------------------------------------------------------------
if (-not $Port) {
    $ports = @(
        Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '\((COM\d+)\)') { [pscustomobject]@{ Port = $Matches[1]; Name = $_.Name } }
        }
    )
    if ($ports.Count -eq 0) {
        Stop-WithError ("No COM port found. Plug the board in with a DATA USB cable, using the port labelled UART " +
            "(the CP2102 one), wait a few seconds, then re-run. The build is finished, so the re-run will be quick.")
    }
    elseif ($ports.Count -eq 1) {
        $Port = $ports[0].Port
        Write-Host "Using $($ports[0].Name)"
    }
    else {
        Write-Host "Several serial ports found:"
        $ports | ForEach-Object { Write-Host "  $($_.Name)" }
        $Port = Read-Host "Type the port to use (for example COM5)"
        if (-not $Port) { Stop-WithError "No port given." }
    }
}

Write-Step "Flashing firmware + model to $Port (the model is written to the SPIFFS 'data' partition)"
Invoke-Idf @("-p", $Port, "-b", "$Baud", "flash") ("If it says 'Failed to connect': hold BOOT, tap RESET, release BOOT, and re-run. " +
    "If flashing is unreliable, re-run with -Baud 115200, or try the other USB port / a different cable.")

# ---------------------------------------------------------------------------
if ($NoMonitor) {
    Write-Host ""
    Write-Host "Done. Flash complete. Open a monitor later with:  idf.py -p $Port monitor" -ForegroundColor Green
    exit 0
}

Write-Step "Opening serial monitor on $Port (press Ctrl+] to quit)"
Write-Host "You should see: 'Found 8MB PSRAM', 'Partition size: total...', 'Successfully read LLM into memory',"
Write-Host "then a short story streaming out, and 'achieved tok/s' at the end."
Write-Host "To generate another story, press the RST/EN button on the board."
Write-Host ""
& python (Join-Path $IdfRoot "tools\idf.py") -p $Port monitor
