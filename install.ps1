# Mario Kart World PC Recompiler for Windows (driven by Switch2Recomp)
# Uses bundled mkw-recomp Windows runtime + portable setup toolchain
# (Python, Zig, glslc, recomp/, sm86/) to recompile the game from a .nup dump (offline, no external download).
param(
    [string]$Nup = "",
    [string]$Dir = "",
    [string]$ShortcutName = "Mario Kart World",
    [string]$IconPath = "",
    [string]$LauncherUiPath = "",
    [switch]$NoDesktopShortcut
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
function Say($msg) { Write-Host "[MKW-PC] $msg" -ForegroundColor Cyan }

if (-not [Environment]::Is64BitOperatingSystem) { Say "64-bit Windows required"; exit 1 }
if (-not $Nup -or -not (Test-Path -LiteralPath $Nup)) { Say "no such file: $Nup"; exit 1 }
if (-not $Dir) {
    $Dir = Join-Path $env:LOCALAPPDATA "Switch2Recomp\Mario Kart World"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
$Nup = [System.IO.Path]::GetFullPath($Nup)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Say "installing into $Dir"

$source = $PSScriptRoot
$builderRoot = Join-Path $Dir "_builder"
$mkwExe = Join-Path $Dir "mkw.exe"
$setupPy = Join-Path $source "toolchain\python\python.exe"
$preparePy = Join-Path $source "tools\prepare\prepare.py"
$buildPy = Join-Path $source "tools\build\build.py"

# ---- 1. Build native Windows PC runtime (mkw.exe) from bundled sources with MSYS2 Clang64 ----
$clang64Bin = "C:\msys64\clang64\bin"
foreach ($req in @($setupPy, $preparePy, $buildPy, (Join-Path $clang64Bin "clang.exe"), (Join-Path $clang64Bin "clang++.exe"), (Join-Path $clang64Bin "ninja.exe"))) {
    if (-not (Test-Path -LiteralPath $req)) {
        Say "error: required component missing: $req"
        exit 1
    }
}

$env:PATH = "$clang64Bin;" + $env:PATH
$env:CLANG64_PREFIX = "C:/msys64/clang64"
$env:MKW_CCACHE = "0"

Say "compiling mkw.exe runtime from sources (MSYS2 Clang64 + Ninja)..."
$rtObjDir = Join-Path $builderRoot "rt_obj"
& $setupPy $buildPy --target windows --dist --runtime-only --dist-dir $Dir --out $rtObjDir
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mkwExe)) {
    Say "error: building mkw.exe runtime failed"
    exit 1
}

# Copy import library for mkwgame.dll linking
$impLibSrc = Join-Path $rtObjDir "libmkw.dll.a"
$impLibDstDir = Join-Path $source "toolchain\lib"
if (Test-Path -LiteralPath $impLibSrc) {
    New-Item -ItemType Directory -Force -Path $impLibDstDir | Out-Null
    Copy-Item -LiteralPath $impLibSrc -Destination (Join-Path $impLibDstDir "libmkw.dll.a") -Force
}

# Copy required MSYS2 Clang64 runtime DLLs next to mkw.exe
foreach ($dll in @("SDL3.dll", "libopus-0.dll", "libvpx-1.dll", "libzstd.dll", "libiconv-2.dll", "libwinpthread-1.dll", "libc++.dll", "libunwind.dll")) {
    $dllSrc = Join-Path $clang64Bin $dll
    if (Test-Path -LiteralPath $dllSrc) {
        Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $Dir $dll) -Force
    }
}

# ---- 2. Ensure default windowed + French settings in mkw.ini (F11 toggles fullscreen) ----
$mkwIni = Join-Path $Dir "mkw.ini"
if (-not (Test-Path -LiteralPath $mkwIni)) {
    @"
[display]
fullscreen = 0
window_size = 1280x720

[language]
lang = fr
menu_lang = fr
"@ | Set-Content -Encoding UTF8 $mkwIni
}

# ---- 3. Run mkw-recomp prepare.py (check, exefs, romfs link, AArch64->C, zig compile, SM86->SPIR-V, warm) ----
Say "running mkw-recomp static recompilation & shader translation (--romfs link)..."
$env:PYTHONUTF8 = "1"
$env:PYTHONUNBUFFERED = "1"

$proc = [System.Diagnostics.Process]::GetCurrentProcess()
$origAffinity = $proc.ProcessorAffinity
$cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
if ($cpuName -match 'Intel.*1[34]\d{3}' -and [Environment]::ProcessorCount -gt 16) {
    # Pin to E-cores (logical processors 16+) on Intel 13th/14th-gen to avoid P-core boost instability during heavy Python/Zig codegen
    $eCoreMask = [int64]0
    for ($c = 16; $c -lt [Math]::Min(63, [Environment]::ProcessorCount); $c++) {
        $eCoreMask = $eCoreMask -bor ([int64]1 -shl $c)
    }
    if ($eCoreMask -gt 0) {
        Say "detected ${cpuName}: pinning codegen & shader build to E-cores for stability"
        $proc.ProcessorAffinity = [IntPtr]$eCoreMask
    }
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & $setupPy $preparePy --source $Nup --game $Dir --runtime $Dir --romfs link --target windows 2>&1 | ForEach-Object {
        $line = "$_"
        if ($line -match '^step\s+(.+)$') {
            Say "step: $($Matches[1])"
        } elseif ($line -match '^skip\s+(.+)$') {
            Say "skip: $($Matches[1]) (already up-to-date)"
        } elseif ($line -match '^progress\s+(\d+)\s+(\d+)$') {
            $done = [int]$Matches[1]
            $tot = [int]$Matches[2]
            if ($tot -gt 0 -and ($done -eq $tot -or $done % 25 -eq 0)) {
                Say "progress: $done / $tot"
            }
        } elseif ($line -match '^error\s+(.+)$') {
            Say "error: $($Matches[1])"
        } elseif ($line -eq 'done') {
            Say "recompilation & shader setup complete!"
        } elseif ($line.Trim()) {
            Say $line
        }
    }
    $prepExit = $LASTEXITCODE
} finally {
    $proc.ProcessorAffinity = $origAffinity
    $ErrorActionPreference = $prevEap
}

if ($prepExit -ne 0) {
    $setupLog = Join-Path $Dir "logs\setup.log"
    if (Test-Path -LiteralPath $setupLog) {
        Say "last lines of logs/setup.log:"
        Get-Content -LiteralPath $setupLog -Tail 30 | ForEach-Object { Write-Host "  $_" }
    }
    Say "mkw-recomp prepare.py failed with exit code $prepExit"
    exit $prepExit
}

$gameDll = Join-Path $Dir "mkwgame.dll"
if (-not (Test-Path -LiteralPath $gameDll)) {
    Say "error: mkwgame.dll was not produced in $Dir"
    exit 1
}

# ---- 4. Pre-launch UI + icons + shortcuts ----
$iconSrc = $IconPath
if (-not $iconSrc -or -not (Test-Path -LiteralPath $iconSrc)) {
    $iconSrc = Join-Path $source "game_icon.ico"
}
$iconDst = Join-Path $Dir "game_icon.ico"
if (Test-Path -LiteralPath $iconSrc) {
    Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force
}
$pngSrc = Join-Path $source "game_icon.png"
$pngDst = Join-Path $Dir "game_icon.png"
if (Test-Path -LiteralPath $pngSrc) {
    Copy-Item -LiteralPath $pngSrc -Destination $pngDst -Force
}

$launcherUiSrc = $LauncherUiPath
if (-not $launcherUiSrc -or -not (Test-Path -LiteralPath $launcherUiSrc)) {
    $repoRoot = Split-Path (Split-Path $source -Parent) -Parent
    $toolsExe = Join-Path $repoRoot "tools\game_launcher.exe"
    $exeCand = Join-Path $repoRoot "game_launcher.exe"
    if (Test-Path -LiteralPath $toolsExe) { $launcherUiSrc = $toolsExe }
    elseif (Test-Path -LiteralPath $exeCand) { $launcherUiSrc = $exeCand }
    else { $launcherUiSrc = Join-Path $repoRoot "src\game_launcher.py" }
}
$isLauncherExe = $launcherUiSrc -match "\.exe$"
$launcherUiDst = Join-Path $Dir $(if ($isLauncherExe) { "game_launcher.exe" } else { "game_launcher.py" })
if (Test-Path -LiteralPath $launcherUiSrc) {
    Copy-Item -LiteralPath $launcherUiSrc -Destination $launcherUiDst -Force
}

$globalSaveDir = Join-Path (Split-Path $Dir -Parent) "Saves\Mario Kart World"
New-Item -ItemType Directory -Force -Path $globalSaveDir | Out-Null
$localProfileDir = Join-Path $Dir "profile"
if ((Test-Path -LiteralPath $localProfileDir) -and -not (Get-ChildItem -LiteralPath $globalSaveDir -Force | Select-Object -First 1)) {
    Get-ChildItem -LiteralPath $localProfileDir -Force | Copy-Item -Destination $globalSaveDir -Recurse -Force -ErrorAction SilentlyContinue
}

$launchTplPath = Join-Path $source "launch_options_template.json"
$launchConfigPath = Join-Path $Dir "launch_options.json"
if (Test-Path -LiteralPath $launchTplPath) {
    $tpl = Get-Content -LiteralPath $launchTplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tpl | Add-Member -NotePropertyName "working_dir" -NotePropertyValue $Dir -Force
    $tpl | Add-Member -NotePropertyName "command" -NotePropertyValue @((Join-Path $Dir "mkw.exe"), "--play") -Force
    if ($tpl.env) {
        $tpl.env | Add-Member -NotePropertyName "MKW_GAME_DIR" -NotePropertyValue $Dir -Force
        $tpl.env | Add-Member -NotePropertyName "MKW_PROFILE_DIR" -NotePropertyValue $globalSaveDir -Force
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($launchConfigPath, ($tpl | ConvertTo-Json -Depth 10), $utf8NoBom)
}

$hostPythonw = $null
$pyCandidates = @(Get-Command pythonw.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source) +
                @(Get-Command python.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
foreach ($cand in $pyCandidates) {
    if ($cand -and ($cand -notmatch "\\msys64\\")) {
        $probeExe = if ($cand -match "pythonw\.exe$") { $cand -replace "pythonw\.exe$", "python.exe" } else { $cand }
        if (Test-Path -LiteralPath $probeExe) {
            & $probeExe -c "import PySide6" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $hostPythonw = $cand
                break
            }
        }
    }
}

$runner = Join-Path $Dir "mkw.cmd"
if ($isLauncherExe -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
@"
@echo off
cd /d "$Dir"
"$launcherUiDst" --config "$launchConfigPath" %*
"@ | Set-Content -Encoding ASCII $runner
} elseif ($hostPythonw -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
@"
@echo off
cd /d "$Dir"
"$hostPythonw" "$launcherUiDst" --config "$launchConfigPath" %*
"@ | Set-Content -Encoding ASCII $runner
} else {
@"
@echo off
cd /d "$Dir"
set "MKW_GAME_DIR=$Dir"
set MKW_FULLSCREEN=0
set MKW_WINDOW_SIZE=1280x720
set MKW_LANG=fr
set MKW_MENU_LANG=fr
"$Dir\mkw.exe" --play %*
"@ | Set-Content -Encoding ASCII $runner
}

$safeShortcutName = ($ShortcutName -replace '[<>:"/\\|?*]+', ' -').Trim()
if (-not $safeShortcutName) { $safeShortcutName = "Mario Kart World" }

$startMenuPrograms = [Environment]::GetFolderPath("Programs")
$shortcutDirs = @((Join-Path $startMenuPrograms $safeShortcutName))
if (-not $NoDesktopShortcut) {
    $shortcutDirs += [Environment]::GetFolderPath("Desktop")
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($sdir in $shortcutDirs) {
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $linkPath = Join-Path $sdir "$safeShortcutName.lnk"
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $runner
    $link.WorkingDirectory = $Dir
    $link.Description = "$safeShortcutName - Native PC port (F11 Fullscreen)"
    if (Test-Path -LiteralPath $iconDst) { $link.IconLocation = "$iconDst,0" }
    $link.Save()
}

# ---- 5. Clean up temporary download folder ----
Say "cleaning up temporary build files..."
if (Test-Path -LiteralPath $builderRoot) {
    Remove-Item -Recurse -Force $builderRoot -ErrorAction SilentlyContinue
}

# ---- 6. Register in Windows Installed Apps + create uninstaller (never deletes the .nup ROM) ----
$uninstKeyName = "Switch2Recomp_" + ($safeShortcutName -replace '[^A-Za-z0-9_-]', '_')
$uninstRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstKeyName"
$uninstPs1 = Join-Path $Dir "uninstall.ps1"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$safeShortcutName.lnk"
$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) $safeShortcutName
$uninstScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$res = [System.Windows.Forms.MessageBox]::Show(
    "Voulez-vous désinstaller $safeShortcutName ?`n`nLe dossier d'installation et les raccourcis seront supprimés.`nVotre fichier ROM (.nup) et vos sauvegardes ne seront PAS supprimés.",
    "Désinstaller $safeShortcutName",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if (`$res -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
if (Test-Path -LiteralPath "$desktopLnk") { Remove-Item -LiteralPath "$desktopLnk" -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$startMenuDir") { Remove-Item -LiteralPath "$startMenuDir" -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$uninstRegPath") {
    Remove-Item -LiteralPath "$uninstRegPath" -Recurse -Force -ErrorAction SilentlyContinue
}
Set-Location `$env:TEMP
Start-Process -FilePath "cmd.exe" -ArgumentList "/c timeout /t 1 /nobreak >nul & rmdir /s /q ``"$Dir``"" -WindowStyle Hidden
"@
[System.IO.File]::WriteAllText($uninstPs1, $uninstScript, (New-Object System.Text.UTF8Encoding($true)))

$sizeKb = [int](((Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
New-Item -Path $uninstRegPath -Force | Out-Null
Set-ItemProperty -Path $uninstRegPath -Name "DisplayName" -Value $safeShortcutName
Set-ItemProperty -Path $uninstRegPath -Name "Publisher" -Value "Switch2Recomp (NUP Studio)"
Set-ItemProperty -Path $uninstRegPath -Name "InstallLocation" -Value $Dir
if (Test-Path -LiteralPath $iconDst) { Set-ItemProperty -Path $uninstRegPath -Name "DisplayIcon" -Value "$iconDst,0" }
$uninstCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "UninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "QuietUninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "NoRepair" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "EstimatedSize" -Value $sizeKb -Type DWord

Say "installed. Start the game from the Start menu or the desktop shortcut (windowed by default, F11 for fullscreen)."
