# ASCII ONLY (PS 5.1 rule).
#
# Hidden at logon. Keeps the USB link armed, launches the headset app when you
# put the Quest on, and does what the headset menu asks for: apply settings
# (restarts SteamVR) and exit (stops it).

$DriverBin = Join-Path $PSScriptRoot 'driver\yoinked\bin\win64'
$NcmFile = "$DriverBin\yoinked_ncm.txt"
$LogFile = "$DriverBin\yoinked_watch.log"
$ApplyFile = "$DriverBin\yoinked_apply.txt"
$QuitFile = "$DriverBin\yoinked_quit.txt"
$AppId = "com.yoinked.client"
$AppActivity = "com.yoinked.client/android.app.NativeActivity"
$ApplyBridge = "/sdcard/Android/data/$AppId/files/apply.txt"
$QuitBridge = "/sdcard/Android/data/$AppId/files/quit.txt"

# One watcher at a time. The mutex is global, so a copy started at logon and
# one started by hand can't both run. (If the previous watcher was killed,
# Windows hands the mutex over with an exception. That still means we own it.)
$mutex = New-Object System.Threading.Mutex($false, 'Global\YoinkedWatchSingleton')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

function Log($msg) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
            Set-Content -Path $LogFile -Value "" -Encoding ascii
        }
        Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format "MM-dd HH:mm:ss"), $msg) -Encoding ascii
    } catch {}
}

function Find-Adb {
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
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

# Only ever act on a Quest, never on a phone that happens to be plugged in.
function Test-IsQuest([string]$adb, [string]$serial) {
    if (-not $adb -or -not $serial) { return $false }
    try {
        $props = & $adb -s $serial shell "getprop ro.product.brand; getprop ro.product.manufacturer; getprop ro.product.model" 2>$null
        return (($props -join ' ') -match '(?i)oculus|meta|quest')
    } catch { return $false }
}

function Find-Serial([string]$adb) {
    if (-not $adb) { return $null }
    try {
        foreach ($ln in (& $adb devices 2>$null)) {
            if ($ln -match '^(\S+)\s+device') {
                $s = $Matches[1]
                if (Test-IsQuest $adb $s) { return $s }
            }
        }
    } catch {}
    return $null
}

# SteamVR records where it lives in openvrpaths.vrpath. Fall back to the
# default Steam folder.
function Get-VrPath([string]$key) {
    try {
        $p = "$env:LOCALAPPDATA\openvr\openvrpaths.vrpath"
        if (Test-Path $p) {
            $j = Get-Content $p -Raw | ConvertFrom-Json
            foreach ($d in @($j.$key)) {
                if ($d -and (Test-Path $d)) { return $d }
            }
        }
    } catch {}
    return $null
}

function Find-Steam {
    $s = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($s) { return ($s -replace '/', '\') }
    return 'C:\Program Files (x86)\Steam'
}

function Find-SteamVR {
    $r = Get-VrPath 'runtime'
    if ($r) { return $r }
    return (Join-Path (Find-Steam) 'steamapps\common\SteamVR')
}

function Find-SteamConfig {
    $c = Get-VrPath 'config'
    if ($c) { return $c }
    return (Join-Path (Find-Steam) 'config')
}

function Stop-SteamVR {
    & taskkill /F /IM vrmonitor.exe /IM vrserver.exe /IM vrcompositor.exe /IM vrdashboard.exe /IM vrwebhelper.exe /IM vrstartup.exe /IM vrservicebridge.exe /IM steamtours.exe 2>$null | Out-Null
    for ($k = 0; $k -lt 20; $k++) {
        if (-not (Get-Process -Name vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
}

# Killing SteamVR makes it start in safe mode next time, which blocks the
# driver and leaves the headset black. Turn that flag back off before relaunching.
function Clear-SafeMode {
    $cfg = Join-Path (Find-SteamConfig) 'steamvr.vrsettings'
    try {
        if (-not (Test-Path $cfg)) { return }
        $txt = [IO.File]::ReadAllText($cfg)
        $new = [regex]::Replace($txt, '("driver_yoinked"\s*:\s*\{[^}]*?"blocked_by_safe_mode"\s*:\s*)true', '${1}false')
        if ($new -ne $txt) {
            [IO.File]::WriteAllText($cfg, $new, (New-Object System.Text.UTF8Encoding($false)))
            Log "cleared safe-mode block on driver_yoinked"
        }
    } catch { Log "safe-mode clear failed: $_" }
}

# Tell the headset to speak USB-NCM, give it an address, and wait (a little)
# for adb to come back.
function Arm-Ncm {
    $script:lastArm = Get-Date
    $out = (& $Adb -s $Serial shell svc usb setFunctions ncm 2>&1 | ForEach-Object { "$_" }) -join ' '
    if ($out.Trim()) { Log ("arm ncm: " + $out.Trim()) }
    Start-Sleep -Seconds 6
    for ($i = 0; $i -lt 15; $i++) {
        $st = (& $Adb -s $Serial get-state 2>$null) -join ''
        if ($st.Trim() -eq 'device') { break }
        Start-Sleep -Seconds 2
    }
    & $Adb -s $Serial shell cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24 2>$null | Out-Null
    & $Adb -s $Serial reverse tcp:9943 tcp:9943 2>$null | Out-Null
}

# Is the direct USB session up (port 9944)? An adb-reverse session (9943) is the
# slow fallback and does not count: keep trying to bring the direct link up.
function Test-DirectLink {
    try {
        foreach ($c in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections()) {
            if ($c.State -eq 'Established' -and $c.RemoteEndPoint.Port -eq 9944) { return $true }
        }
    } catch {}
    return $false
}

# Any session at all, direct or over adb.
function Test-AnyLink {
    try {
        foreach ($c in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections()) {
            if ($c.State -ne 'Established') { continue }
            if ($c.RemoteEndPoint.Port -eq 9944) { return $true }
            if ($c.LocalEndPoint.Port -eq 9943) { return $true }
        }
    } catch {}
    return $false
}

# The headset menu runs before SteamVR is up, so it can't send a message. It
# leaves a small request file in the app's folder instead, which plain adb can
# read. Both requests can restart or stop SteamVR, so each must run once at
# most: delete the file first, skip it if the delete didn't take, and drop
# anything older than 10 minutes (judged by the headset's own clock).
# Returns the request text, or $null when there is nothing to act on.
function Take-Request([string]$path, [string]$what) {
    $raw = ""
    try { $raw = (& $Adb -s $Serial shell "cat $path 2>/dev/null" 2>$null | Select-Object -First 1) } catch {}
    if (-not $raw) { return $null }
    $age = 0
    try {
        $t = & $Adb -s $Serial shell "echo `$(date +%s) `$(stat -c %Y $path 2>/dev/null)" 2>$null | Select-Object -First 1
        if ($t -match '^\s*(\d+)\s+(\d+)') { $age = [int]$Matches[1] - [int]$Matches[2] }
    } catch {}
    & $Adb -s $Serial shell "rm -f $path" 2>$null | Out-Null
    $left = ""
    try { $left = (& $Adb -s $Serial shell "cat $path 2>/dev/null" 2>$null | Select-Object -First 1) } catch {}
    if ($left) {
        Log "$what SKIPPED - could not delete $path (would loop)"
        return $null
    }
    if ($age -gt 600) {
        Log "$what DISCARDED (stale by $age s)"
        return $null
    }
    return "$raw"
}

# APPLY from the headset menu: restart SteamVR (or start it) with the new settings.
function Do-Apply {
    if (-not (Test-Path $ApplyFile)) { return }
    $req = ""
    try { $req = (Get-Content $ApplyFile -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
    Remove-Item $ApplyFile -Force -ErrorAction SilentlyContinue
    if (Get-Process -Name vrserver -ErrorAction SilentlyContinue) {
        Log "apply request ($req) - restarting SteamVR"
    } else {
        Log "apply request ($req) - SteamVR not running, starting it"
    }
    Stop-SteamVR
    Start-Sleep -Seconds 2
    Clear-SafeMode
    $vrStartup = Join-Path (Find-SteamVR) 'bin\win64\vrstartup.exe'
    if (Test-Path $vrStartup) {
        Start-Process $vrStartup -ErrorAction SilentlyContinue
        Log "apply done - SteamVR relaunched"
    } else {
        Log "apply FAILED - vrstartup.exe not found at $vrStartup"
    }
}

# EXIT from the headset menu: stop SteamVR and stay in the headset's own lobby.
function Do-Quit {
    if (-not (Test-Path $QuitFile)) { return }
    Remove-Item $QuitFile -Force -ErrorAction SilentlyContinue
    if (Get-Process -Name vrserver -ErrorAction SilentlyContinue) {
        Log "exit request - stopping SteamVR"
        Stop-SteamVR
        Log "exit done - SteamVR down"
    } else {
        Log "exit request - SteamVR already down"
    }
}

# A request left over from before the watcher started is old news.
foreach ($f in $ApplyFile, $QuitFile) {
    if ((Test-Path $f) -and ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -gt 600) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
}

$Adb = Find-Adb
$Serial = $null

Log "watcher up (pid $PID)"
$lastArm = [DateTime]::MinValue
$lastAppStart = [DateTime]::MinValue
$lastKick = [DateTime]::MinValue
$appearedAt = [DateTime]::MinValue
$noSessionSince = $null
$wasPresent = $false
$launchedThisWake = $false
$usbDownHits = 0

while ($true) {
    # The watcher starts at logon, usually before the headset is plugged in, so
    # look for the Quest on every pass until one shows up.
    $present = $false
    if (-not $Adb) { $Adb = Find-Adb }
    if (-not $Serial) { $Serial = Find-Serial $Adb }
    if ($Serial -and $Adb) {
        try {
            foreach ($ln in (& $Adb devices 2>$null)) {
                if ($ln -match "^$([regex]::Escape($Serial))\s+device") { $present = $true }
            }
        } catch {}
    }

    if (-not $present) {
        if ($wasPresent) {
            Log "device gone"
            $Serial = $null
            $launchedThisWake = $false
            $noSessionSince = $null
        }
        $wasPresent = $false
        Start-Sleep -Seconds 5
        continue
    }

    if (-not $wasPresent) {
        Log "device appeared"
        $appearedAt = Get-Date
        $launchedThisWake = $false
        $lastArm = [DateTime]::MinValue
        & $Adb -s $Serial reverse tcp:9943 tcp:9943 2>$null | Out-Null
        & $Adb -s $Serial shell settings put secure skip_launch_check_requires_controllers_enabled true 2>$null | Out-Null
    }
    $wasPresent = $true

    # Stay out of the way while streaming. Every adb call below is a round trip
    # on the same cable that carries the video, and a disturbance you can feel.
    # Still look for a menu request every couple of seconds, so APPLY does not
    # sit and wait.
    $vrUp = [bool](Get-Process -Name vrserver -ErrorAction SilentlyContinue)
    if ($vrUp -and (Test-DirectLink)) {
        for ($i = 0; $i -lt 15; $i++) {
            if ((Test-Path $ApplyFile) -or (Test-Path $QuitFile)) { break }
            Start-Sleep -Seconds 2
        }
        Do-Apply
        Do-Quit
        continue
    }

    $devLL = $null
    try {
        $out = & $Adb -s $Serial shell "ip -6 addr show usb0 scope link 2>/dev/null" 2>$null
        $m = [regex]::Match(($out -join " "), "inet6\s+(fe80:[0-9a-f:]+)/64")
        if ($m.Success) { $devLL = $m.Groups[1].Value }
    } catch {}

    # After the headset (re)appears, retry every 15 s for 3 minutes: arming
    # fails while the Quest is still starting up. Then once a minute.
    $armEvery = 60
    if (((Get-Date) - $appearedAt).TotalSeconds -lt 180) { $armEvery = 15 }

    if (-not $devLL) {
        $usbDownHits++
        # One empty read can just be a busy adb, and arming would bounce a
        # working link. Two in a row (~10 s) means usb0 really is gone.
        if ($usbDownHits -ge 2 -and ((Get-Date) - $lastArm).TotalSeconds -gt $armEvery) {
            Log "usb0 down - arming ncm"
            Arm-Ncm
        }
    } else {
        $usbDownHits = 0
        $nic = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match "UsbNcm|NCM" -and $_.Status -eq "Up" } |
            Select-Object -First 1
        if (-not $nic) {
            # The headset has usb0 but Windows hasn't brought up its side. Arming
            # again makes Windows look again. Without this everything quietly
            # falls back to the slow link.
            if (((Get-Date) - $lastArm).TotalSeconds -gt $armEvery) {
                Log "usb0 up on the headset but no NCM adapter on this PC - re-arming"
                Arm-Ncm
            }
        } else {
            $target = "$devLL%$($nic.InterfaceIndex)"
            $cur = ""
            try { $cur = (Get-Content $NcmFile -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
            if ($cur -ne $target) {
                Set-Content -Path $NcmFile -Value $target -Encoding ascii
                Log "dial target updated: $target"
            }
        }
    }

    # APPLY pressed in the headset menu before SteamVR was running.
    $req = Take-Request $ApplyBridge "in-headset apply"
    if ($req) {
        if ($req -match '^\s*(\d+)\s+(\d+)(?:\s+(\d+))?') {
            $bHz = [int]$Matches[1]; $bDx = [int]$Matches[2]
            $bPl = 0
            if ($Matches[3]) { $bPl = [int]$Matches[3] }
            if (($bHz -in 72,80,90,120) -and $bDx -ge 10 -and $bDx -le 20) {
                $res = "{0}.{1}" -f [math]::Floor($bDx / 10), ($bDx % 10)
                Set-Content -Path "$DriverBin\yoinked_refresh.txt" -Value $bHz -Encoding ascii
                Set-Content -Path "$DriverBin\yoinked_stream_res.txt" -Value $res -Encoding ascii
                $pacing = "unchanged"
                if ($bPl -ge 1 -and $bPl -le 3) {
                    Set-Content -Path "$DriverBin\yoinked_pipeline.txt" -Value $bPl -Encoding ascii
                    if ($bPl -eq 1) { $pacing = "SNAP" }
                    elseif ($bPl -eq 2) { $pacing = "FAST" }
                    else { $pacing = "SMOOTH" }
                }
                Log "in-headset apply: $bHz Hz, ${res}x, pacing $pacing"
                Set-Content -Path $ApplyFile -Value "$bHz $bDx" -Encoding ascii
            } else {
                Log "in-headset apply IGNORED (out of range): hz=$bHz dx10=$bDx"
            }
        } else {
            Log "in-headset apply IGNORED (unreadable): $req"
        }
    }
    Do-Apply

    # EXIT pressed in the headset menu.
    $req = Take-Request $QuitBridge "in-headset exit"
    if ($req) {
        if ($req -match '(?i)quit') { Set-Content -Path $QuitFile -Value "1" -Encoding ascii }
        else { Log "in-headset exit IGNORED (unreadable): $req" }
    }
    Do-Quit

    # Launch the headset app when the headset is awake (on your head), so
    # putting it on is all it takes. Once per wake, so closing the app on
    # purpose sticks, except while SteamVR is up: that means you want to play.
    $awake = $false
    try {
        $wf = & $Adb -s $Serial shell "dumpsys power | grep -m1 mWakefulness" 2>$null
        if (($wf -join " ") -match "mWakefulness=Awake") { $awake = $true }
    } catch {}
    if (-not $awake) {
        $launchedThisWake = $false
        $noSessionSince = $null
    } elseif (((Get-Date) - $lastAppStart).TotalSeconds -gt 15) {
        $appPid = & $Adb -s $Serial shell pidof $AppId 2>$null
        $vrUp = [bool](Get-Process -Name vrserver -ErrorAction SilentlyContinue)
        if ($appPid) {
            $launchedThisWake = $true
            # After a headset reboot the app can be up but not listening, and
            # SteamVR then waits for it forever. If SteamVR has been up for
            # ~20 s with no session, restart the app.
            if ($vrUp -and -not (Test-AnyLink)) {
                if ($null -eq $noSessionSince) { $noSessionSince = Get-Date }
                if (((Get-Date) - $noSessionSince).TotalSeconds -gt 20 -and ((Get-Date) - $lastKick).TotalSeconds -gt 25) {
                    $lastKick = Get-Date
                    $lastAppStart = Get-Date
                    $noSessionSince = $null
                    Log "SteamVR up but no yoinked session - restarting the headset app"
                    & $Adb -s $Serial reverse tcp:9943 tcp:9943 2>$null | Out-Null
                    & $Adb -s $Serial shell am force-stop $AppId 2>$null | Out-Null
                    Start-Sleep -Seconds 1
                    & $Adb -s $Serial shell am start -n $AppActivity 2>$null | Out-Null
                }
            } else {
                $noSessionSince = $null
            }
        } elseif ((-not $launchedThisWake) -or $vrUp) {
            $lastAppStart = Get-Date
            $launchedThisWake = $true
            Log "headset awake + app dead - launching Yoinked"
            & $Adb -s $Serial shell am start -n $AppActivity 2>$null | Out-Null
        }
    }

    Start-Sleep -Seconds 5
}
