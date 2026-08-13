# yoinked installer
#
#   irm https://raw.githubusercontent.com/critzydev/yoinked-vr/main/install.ps1 | iex
#
# Downloads yoinked, registers the SteamVR driver, installs the headset app,
# sets up the direct USB link, and makes it all start on its own.
#
# Safe to run again any time - it skips whatever is already done and never
# overwrites settings you have changed.

param(
    [string]$Root = "$env:LOCALAPPDATA\yoinked",
    [switch]$NoHeadset
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # keeps Invoke-WebRequest quiet and fast
$problems = @()

function Head($t) { Write-Host ""; Write-Host $t -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  ok    $t" -ForegroundColor Green }
function Doing($t){ Write-Host "        $t" -ForegroundColor DarkGray }
function Nope($t) { Write-Host "  !!    $t" -ForegroundColor Red; $script:problems += $t }
function Hmm($t)  { Write-Host "  ..    $t" -ForegroundColor Yellow }

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

    # Keep any settings already tuned on this machine.
    $liveCfg = Join-Path $Root 'driver\yoinked\bin\win64'
    $keep = @{}
    if (Test-Path $liveCfg) {
        foreach ($f in Get-ChildItem $liveCfg -Filter '*.txt') { $keep[$f.Name] = Get-Content $f.FullName -Raw }
    }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Copy-Item (Join-Path $src.FullName '*') $Root -Recurse -Force
    foreach ($k in $keep.Keys) { Set-Content -Path (Join-Path $liveCfg $k) -Value $keep[$k] -NoNewline }
    if ($keep.Count) { Ok "updated, kept your $($keep.Count) settings files" } else { Ok "installed to $Root" }
} catch {
    Nope "download failed: $($_.Exception.Message)"
    return
} finally {
    Remove-Item $zip -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------ adb
Head "Tools"
function Have($c) { return [bool](Get-Command $c -ErrorAction SilentlyContinue) }
if (Have adb) {
    Ok "adb present"
} else {
    Doing "installing Android platform-tools (for talking to the headset)..."
    if (Have winget) {
        winget install --id Google.PlatformTools -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    }
    if (Have adb) { Ok "adb installed" } else { Nope "could not install adb. Get it from developer.android.com/tools/releases/platform-tools and re-run." }
}

# -------------------------------------------------------------------- SteamVR
Head "SteamVR"
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }
$vrpathreg = Join-Path $steam 'steamapps\common\SteamVR\bin\win64\vrpathreg.exe'
$driverDir = Join-Path $Root 'driver\yoinked'
if (Test-Path $vrpathreg) {
    & $vrpathreg adddriver $driverDir 2>&1 | Out-Null
    Ok "driver registered"
} else {
    Nope "SteamVR not found. Install it from Steam, then run this again."
}

# -------------------------------------------------------------------- headset
if (-not $NoHeadset -and (Have adb)) {
    Head "Headset"
    Write-Host ""
    Write-Host "   Plug your Quest into this PC with a USB 3 cable and put it on." -ForegroundColor White
    Write-Host ""
    Write-Host "   It needs Developer Mode: Meta Horizon phone app -> your headset" -ForegroundColor DarkGray
    Write-Host "   -> Headset Settings -> Developer Mode. Then a prompt appears IN" -ForegroundColor DarkGray
    Write-Host "   the headset asking to allow USB debugging - say yes and tick" -ForegroundColor DarkGray
    Write-Host "   'Always allow'." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "   Press Enter when it's plugged in and on your head"

    $serial = $null
    for ($i = 0; $i -lt 40; $i++) {
        $d = @(& adb devices 2>$null | Select-String "`tdevice$")
        if ($d.Count) { $serial = ($d[0] -split '\s+')[0]; break }
        if (@(& adb devices 2>$null | Select-String 'unauthorized').Count) {
            Hmm "waiting - accept the USB debugging prompt in the headset"
        }
        Start-Sleep -Seconds 2
    }

    if (-not $serial) {
        Nope "couldn't reach the headset. Check the cable (USB 3), Developer Mode, and the in-headset prompt."
    } else {
        Ok "found your headset"
        Doing "installing the app..."
        & adb -s $serial install -r (Join-Path $Root 'yoinked.apk') 2>&1 | Select-String 'Success' | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "app installed" } else { Nope "app install failed" }

        Doing "setting up the direct USB link (the headset drops off adb briefly)..."
        & adb -s $serial shell svc usb setFunctions ncm 2>&1 | Out-Null
        Start-Sleep -Seconds 6
        & adb wait-for-device 2>&1 | Out-Null
        & adb -s $serial shell cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24 2>&1 | Out-Null

        $ll = $null
        for ($i = 0; $i -lt 20; $i++) {
            $o = & adb -s $serial shell "ip -6 addr show usb0 scope link 2>/dev/null" 2>$null
            if ($o -match 'inet6\s+(fe80::[0-9a-f:]+)') { $ll = $Matches[1]; break }
            Start-Sleep -Seconds 1
        }
        $ifIndex = (Get-NetAdapter -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceDescription -like '*UsbNcm*' } |
                    Select-Object -First 1).ifIndex
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
Write-Host "  Settings are in the headset: left grip + menu." -ForegroundColor DarkGray
Write-Host "  Menu tap pauses the game. STEAMVR on the overlay opens the dashboard." -ForegroundColor DarkGray
Write-Host "  Installed at $Root" -ForegroundColor DarkGray
Write-Host ""
