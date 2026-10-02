# yoinked installer
#
#   irm https://raw.githubusercontent.com/critzydev/yoinked-vr/main/install.ps1 | iex
#
# Downloads yoinked, registers the SteamVR driver, installs the headset app,
# sets up the direct USB link, and makes it all start on its own.
#
# Safe to run again any time - it updates what is there and never overwrites
# settings you have changed. Close SteamVR first: it keeps the driver's files
# open while it runs.

param(
    [string]$Root = "$env:LOCALAPPDATA\yoinked",
    [switch]$NoHeadset
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # keeps Invoke-WebRequest quiet and fast
$problems = @()
$AppId = 'com.yoinked.client'

function Head($t) { Write-Host ""; Write-Host $t -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  ok    $t" -ForegroundColor Green }
function Doing($t){ Write-Host "        $t" -ForegroundColor DarkGray }
function Nope($t) { Write-Host "  !!    $t" -ForegroundColor Red; $script:problems += $t }
function Hmm($t)  { Write-Host "  ..    $t" -ForegroundColor Yellow }

# ---------------------------------------------------------------------- helpers
function Find-Adb {
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    )) {
        if (Test-Path $c) { return $c }
    }
    $pkg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter 'Google.PlatformTools*' -Directory -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($pkg) {
        $a = Get-ChildItem $pkg.FullName -Filter adb.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($a) { return $a.FullName }
    }
    return $null
}

# adb's output as one string, never throwing. PowerShell 5.1 turns a native
# command's stderr (where adb reports install failures) into an error that
# would end the whole script.
function Invoke-Adb([string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return ((& $adb @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n")
    } finally {
        $ErrorActionPreference = $old
    }
}

# The first authorised device that is a Quest. A phone on the same PC should
# not have its USB mode changed.
function Find-Quest {
    foreach ($ln in ((Invoke-Adb @('devices')) -split "`n")) {
        if ($ln -match '^(\S+)\s+device\s*$') {
            $s = $Matches[1]
            $props = Invoke-Adb @('-s', $s, 'shell', 'getprop ro.product.brand; getprop ro.product.manufacturer; getprop ro.product.model')
            if ($props -match '(?i)oculus|meta|quest') { return $s }
        }
    }
    return $null
}

function Wait-Device([string]$serial) {
    for ($i = 0; $i -lt 20; $i++) {
        if ((Invoke-Adb @('-s', $serial, 'get-state')).Trim() -eq 'device') { return }
        Start-Sleep -Seconds 2
    }
}

# SteamVR writes down where it lives. Fall back to the default Steam folder.
function Find-SteamVR {
    try {
        $p = "$env:LOCALAPPDATA\openvr\openvrpaths.vrpath"
        if (Test-Path $p) {
            $j = Get-Content $p -Raw | ConvertFrom-Json
            foreach ($d in @($j.runtime)) {
                if ($d -and (Test-Path $d)) { return $d }
            }
        }
    } catch {}
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) { $steam = $steam -replace '/', '\' } else { $steam = 'C:\Program Files (x86)\Steam' }
    return (Join-Path $steam 'steamapps\common\SteamVR')
}

# What the app saved from its menu (its only data), or $null. Reading it needs
# a debuggable build, which every build of the app is.
function Get-AppSettings([string]$serial) {
    $s = (Invoke-Adb @('-s', $serial, 'shell', "run-as $AppId cat files/settings.txt")).Trim()
    if ($s -match '^\d+( \d+){2,5}$') { return $s }
    return $null
}

function Set-AppSettings([string]$serial, [string]$settings) {
    # Digits and spaces only (checked above), so it is safe to put in a command.
    Invoke-Adb @('-s', $serial, 'shell', "run-as $AppId sh -c 'mkdir -p files && echo $settings > files/settings.txt'") | Out-Null
}

# Puts the app on the headset. Every PC signs its own debug builds, so an app
# that came from another PC cannot be updated in place: remove it, install
# this one, and put its settings back. $true when the app ends up installed.
function Install-App([string]$serial, [string]$apk) {
    $out = Invoke-Adb @('-s', $serial, 'install', '-r', $apk)
    if ($out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        Doing "the app on the headset came from another PC - reinstalling it"
        $settings = Get-AppSettings $serial
        Invoke-Adb @('-s', $serial, 'uninstall', $AppId) | Out-Null
        $out = Invoke-Adb @('-s', $serial, 'install', $apk)
        if ($out -match 'Success') {
            if (-not $settings) {
                Hmm "couldn't read your old headset settings - set them again in the wrist menu"
            } else {
                Set-AppSettings $serial $settings
                if ((Get-AppSettings $serial) -eq $settings) {
                    Doing "kept your headset settings ($settings)"
                } else {
                    Hmm "couldn't put your old headset settings back ($settings) - set them again in the wrist menu"
                }
            }
        }
    }
    if ($out -match 'Success') {
        Invoke-Adb @('-s', $serial, 'shell', 'pm', 'grant', $AppId, 'android.permission.POST_NOTIFICATIONS') | Out-Null
        return $true
    }
    Doing ($out.Trim())
    return $false
}

# Any running watcher, whichever copy it was started from.
function Stop-Watcher {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -like '*yoinked-watch.ps1*' -and $_.ProcessId -ne $PID })
    $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    return $procs.Count
}

Write-Host ""
Write-Host "  yoinked" -ForegroundColor Cyan
Write-Host "  wired PCVR for Quest 3" -ForegroundColor DarkGray

# ------------------------------------------------------------------- download
Head "Getting yoinked"
$zip = Join-Path $env:TEMP 'yoinked-vr.zip'
$tmp = Join-Path $env:TEMP 'yoinked-vr-extract'
try {
    Doing "downloading..."
    Invoke-WebRequest -Uri 'https://github.com/critzydev/yoinked-vr/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
} catch {
    Nope "download failed: $($_.Exception.Message)"
    Remove-Item $zip -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

# SteamVR keeps the driver's DLLs open, so they can't be replaced while it runs.
if (Get-Process -Name vrserver -ErrorAction SilentlyContinue) {
    Hmm "SteamVR is running. Close it and this carries on by itself."
    for ($i = 0; $i -lt 150; $i++) {
        if (-not (Get-Process -Name vrserver -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 2
    }
    if (Get-Process -Name vrserver -ErrorAction SilentlyContinue) {
        Nope "SteamVR is still running. Close it and run this again."
        Remove-Item $zip -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Start-Sleep -Seconds 3   # let it let go of the files
}

try {
    # Keep any settings already tuned on this machine (byte for byte).
    $liveCfg = Join-Path $Root 'driver\yoinked\bin\win64'
    $keep = @{}
    if (Test-Path $liveCfg) {
        foreach ($f in Get-ChildItem $liveCfg -Filter '*.txt') { $keep[$f.Name] = [IO.File]::ReadAllBytes($f.FullName) }
    }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Copy-Item (Join-Path $src.FullName '*') $Root -Recurse -Force
    foreach ($k in $keep.Keys) { [IO.File]::WriteAllBytes((Join-Path $liveCfg $k), $keep[$k]) }
    if ($keep.Count) { Ok "updated, kept your $($keep.Count) settings files" } else { Ok "installed to $Root" }
} catch {
    Nope "could not copy the files: $($_.Exception.Message)"
    return
} finally {
    Remove-Item $zip -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------ adb
Head "Tools"
$adb = Find-Adb
if ($adb) {
    Ok "adb present"
} else {
    Doing "installing Android platform-tools (for talking to the headset)..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Google.PlatformTools -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    }
    $adb = Find-Adb
    if ($adb) { Ok "adb installed" } else { Nope "could not install adb. Get it from developer.android.com/tools/releases/platform-tools and re-run." }
}

# -------------------------------------------------------------------- SteamVR
Head "SteamVR"
$vrpathreg = Join-Path (Find-SteamVR) 'bin\win64\vrpathreg.exe'
$driverDir = Join-Path $Root 'driver\yoinked'
if (Test-Path $vrpathreg) {
    & $vrpathreg adddriver $driverDir 2>&1 | Out-Null
    Ok "driver registered"
} else {
    Nope "SteamVR not found. Install it from Steam, then run this again."
}

# ---------------------------------------------------------------------- audio
# The headset hears one Windows output. Asked once; the picker can be run again
# whenever you want to change it.
Head "Headset audio"
$audioFile = Join-Path $Root 'driver\yoinked\bin\win64\yoinked_audio.txt'
$audioPicker = Join-Path $Root 'audio-device.ps1'
if (Test-Path $audioFile) {
    $heard = "$([IO.File]::ReadAllText($audioFile))".Trim()
    if (-not $heard -or $heard -eq 'default') { $heard = 'the Windows default output' }
    Ok "the headset hears $heard"
} elseif (Test-Path $audioPicker) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $audioPicker
    } catch {
        Hmm "couldn't ask - the headset will hear the Windows default output"
    }
} else {
    Hmm "audio-device.ps1 is missing - the headset will hear the Windows default output"
}
Doing "change it any time: powershell -ExecutionPolicy Bypass -File `"$audioPicker`""

# -------------------------------------------------------------------- headset
if (-not $NoHeadset -and $adb) {
    Head "Headset"
    $serial = Find-Quest
    if (-not $serial) {
        Write-Host ""
        Write-Host "   Plug your Quest into this PC with a USB 3 cable and put it on." -ForegroundColor White
        Write-Host ""
        Write-Host "   It needs Developer Mode: Meta Horizon phone app -> your headset" -ForegroundColor DarkGray
        Write-Host "   -> Headset Settings -> Developer Mode. Then a prompt appears IN" -ForegroundColor DarkGray
        Write-Host "   the headset asking to allow USB debugging - say yes and tick" -ForegroundColor DarkGray
        Write-Host "   'Always allow'." -ForegroundColor DarkGray
        Write-Host ""
        Read-Host "   Press Enter when it's plugged in and on your head"

        for ($i = 0; $i -lt 40; $i++) {
            $serial = Find-Quest
            if ($serial) { break }
            if ((Invoke-Adb @('devices')) -match 'unauthorized') {
                Hmm "waiting - accept the USB debugging prompt in the headset"
            }
            Start-Sleep -Seconds 2
        }
    }

    if (-not $serial) {
        Nope "couldn't reach the headset. Check the cable (USB 3), Developer Mode, and the in-headset prompt."
    } else {
        Ok "found your headset"
        Doing "installing the app..."
        if (Install-App $serial (Join-Path $Root 'yoinked.apk')) { Ok "app installed" } else { Nope "app install failed" }

        Doing "setting up the direct USB link (the headset drops off adb briefly)..."
        Invoke-Adb @('-s', $serial, 'shell', 'svc', 'usb', 'setFunctions', 'ncm') | Out-Null
        Start-Sleep -Seconds 6
        Wait-Device $serial
        Invoke-Adb @('-s', $serial, 'shell', 'cmd', 'ethernet', 'set-ip-configuration', 'usb0', 'static', '192.168.42.2/24') | Out-Null

        $ll = $null
        for ($i = 0; $i -lt 20; $i++) {
            $o = Invoke-Adb @('-s', $serial, 'shell', 'ip -6 addr show usb0 scope link 2>/dev/null')
            if ($o -match 'inet6\s+(fe80:[0-9a-f:]+)/64') { $ll = $Matches[1]; break }
            Start-Sleep -Seconds 1
        }
        $ifIndex = $null
        for ($i = 0; $i -lt 10; $i++) {
            $ifIndex = (Get-NetAdapter -ErrorAction SilentlyContinue |
                        Where-Object { $_.InterfaceDescription -like '*UsbNcm*' } |
                        Select-Object -First 1).ifIndex
            if ($ifIndex) { break }
            Start-Sleep -Seconds 1
        }
        if ($ll -and $ifIndex) {
            Set-Content -Path (Join-Path $Root 'driver\yoinked\bin\win64\yoinked_ncm.txt') -Value "$ll%$ifIndex" -Encoding ascii
            Ok "direct USB link ready"
        } else {
            Hmm "direct link not up yet - yoinked will still work over the slower fallback. Re-run this later to fix it."
        }
    }
}

# ------------------------------------------------------------------ auto-start
Head "Auto-start"
$watch = Join-Path $Root 'yoinked-watch.ps1'
if (Test-Path $watch) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'yoinked.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = 'powershell.exe'
    $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watch`""
    $s.WorkingDirectory = $Root
    $s.Save()
    Ok "yoinked will start with Windows and launch itself when you put the headset on"

    # Start the new copy now instead of waiting for the next logon. It is
    # created through WMI, not Start-Process: a child of this window would die
    # when the window closes, and this one has to keep running.
    $old = Stop-Watcher
    $cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watch`""
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $Root }
    if ($r.ReturnValue -eq 0) {
        if ($old) { Ok "restarted the background helper" } else { Ok "background helper running" }
    } else {
        Nope "could not start the background helper (error $($r.ReturnValue)). It will start at your next logon."
    }
}

# ---------------------------------------------------------------------- finish
Write-Host ""
if ($problems.Count -eq 0) {
    Write-Host "  All set." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Start SteamVR, put the headset on, and play." -ForegroundColor White
} else {
    Write-Host "  Finished, but:" -ForegroundColor Yellow
    foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "  Menu tap pauses the game." -ForegroundColor DarkGray
Write-Host "  Hold the left menu button for half a second to open the wrist" -ForegroundColor DarkGray
Write-Host "  watch: refresh rate, density and pacing, the SteamVR dashboard, exit." -ForegroundColor DarkGray
Write-Host "  Installed at $Root" -ForegroundColor DarkGray
Write-Host ""
