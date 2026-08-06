# ASCII ONLY (PS 5.1 rule).
#
# Everything adb-side that the stack needs is kept armed continuously by this
# watcher, which runs hidden at logon (scheduled task "YoinkedWatch"):
#   - USB gadget kept in ncm mode (armed once when missing, never bounced
#     when already up - setFunctions re-enumerates, so only fire on absence)
#   - yoinked_ncm.txt kept pointing at the CURRENT fe80%ifIndex dial target
#     (headset reboots change the address; SteamVR restart adopts)
#   - adb reverse tcp:9943 re-applied whenever the device (re)appears
#   - the "controllers required" launch-check skip re-asserted (the OS
#     resets it after user sessions; harmless when already true)
# It launches the headset app on wake / when SteamVR starts (the appliance
# flow below), but never kills adb (shared with user tooling).

# to one machine - this script is the appliance's always-on piece and has to
# work unchanged on the second rig.
. (Join-Path $PSScriptRoot 'rig-config.ps1')
$Adb = $RigAdb
$Serial = $RigSerial
$DriverBin = $RigDriverBin
$NcmFile = "$DriverBin\yoinked_ncm.txt"
$LogFile = "$DriverBin\yoinked_watch.log"
$ApplyFile = "$DriverBin\yoinked_apply.txt"
$M4Run = Join-Path $PSScriptRoot 'm4-run.ps1'
$AppId = "com.yoinked.client"
$AppActivity = "com.yoinked.client/android.app.NativeActivity"

# Single instance via a named mutex. (The old cmdline-match approach caught
# any launcher/diagnostic PowerShell that merely MENTIONED the script path,
# so the watcher exited before it ever ran - untestable and fragile.) The
# mutex releases automatically when this process exits.
$mutex = New-Object System.Threading.Mutex($false, 'YoinkedWatchSingleton')
if (-not $mutex.WaitOne(0)) { exit 0 }

function Log($msg) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
            Set-Content -Path $LogFile -Value "" -Encoding ascii
        }
        Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format "MM-dd HH:mm:ss"), $msg) -Encoding ascii
    } catch {}
}

Log "watcher up (pid $PID)"
$lastArm = [DateTime]::MinValue
$lastAppStart = [DateTime]::MinValue
$wasPresent = $false
$launchedThisWake = $false
# the last observed app liveness so the backoff can engage without spending a
# USB round trip; lastStreamCheck paces the ~3 min liveness re-check.
$script:appWasRunning = $false
$script:lastStreamCheck = [DateTime]::MinValue

while ($true) {
    # asleep, so auto-detection at startup usually finds nothing. Re-detect the
    # serial here each pass until one shows up (and after a swap), instead of
    # binding once at launch. An explicit YOINKED_SERIAL / rig-config.local.ps1
    # still wins because Find-RigSerial checks it first.
    $present = $false
    if (-not $Serial) { $Serial = Find-RigSerial $RigAdb }
    if ($Serial) {
        try {
            foreach ($ln in (& $Adb devices 2>$null)) {
                if ($ln -match "^$([regex]::Escape($Serial))\s+device") { $present = $true }
            }
        } catch {}
    }

    if (-not $present) {
        if ($wasPresent) { Log "device gone" ; $Serial = $null }
        $wasPresent = $false
        Start-Sleep -Seconds 5
        continue
    }

    if (-not $wasPresent) {
        Log "device appeared"
        & $Adb -s $Serial reverse tcp:9943 tcp:9943 2>$null | Out-Null
        & $Adb -s $Serial shell settings put secure skip_launch_check_requires_controllers_enabled true 2>$null | Out-Null
    }
    $wasPresent = $true

    # commands - each one a USB round trip that also spawns a process on the
    # headset, and `dumpsys power` is not cheap there. That ran every 5 SECONDS
    # on the exact same USB link that is carrying ~195 Mbps of video, and on the
    # same little cores as the decoder and render threads. It is a periodic,
    # "cable interference".
    #
    # Once we are streaming, none of it is needed: NCM is up (that is what the
    # stream rides), the app is running, and the in-headset Apply goes over the
    # wire rather than the file bridge (the bridge exists for the no-wire case).
    # So: poll at 30 s instead of 5 s, and do one cheap liveness check every
    # ~3 minutes so an app crash is still noticed promptly.
    $vrUpLocal = [bool](Get-Process -Name vrserver -ErrorAction SilentlyContinue)
    if ($vrUpLocal -and $script:appWasRunning) {
        if (((Get-Date) - $script:lastStreamCheck).TotalSeconds -lt 180) {
            Start-Sleep -Seconds 30
            continue
        }
        $script:lastStreamCheck = Get-Date
        $alive = & $Adb -s $Serial shell pidof $AppId 2>$null
        if (-not $alive) {
            Log "app died while streaming - resuming normal polling"
            $script:appWasRunning = $false
        } else {
            Start-Sleep -Seconds 30
            continue
        }
    }

    # NCM state: fe80 on usb0 = armed; arm at most once per minute otherwise.
    $devLL = $null
    try {
        $out = & $Adb -s $Serial shell "ip -6 addr show usb0 scope link 2>/dev/null" 2>$null
        $m = [regex]::Match(($out -join " "), "inet6\s+(fe80:[0-9a-f:]+)/64")
        if ($m.Success) { $devLL = $m.Groups[1].Value }
    } catch {}

    if (-not $devLL) {
        if (((Get-Date) - $lastArm).TotalSeconds -gt 60) {
            $lastArm = Get-Date
            Log "usb0 down - arming ncm"
            & $Adb -s $Serial shell svc usb setFunctions ncm 2>$null | Out-Null
            Start-Sleep -Seconds 6
            & $Adb wait-for-device 2>$null | Out-Null
            & $Adb -s $Serial shell cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24 2>$null | Out-Null
            & $Adb -s $Serial reverse tcp:9943 tcp:9943 2>$null | Out-Null
        }
        Start-Sleep -Seconds 5
        continue
    }

    # Keep the dial target current (device fe80 + PC NCM ifIndex).
    $nic = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match "UsbNcm|NCM" -and $_.Status -eq "Up" } |
        Select-Object -First 1
    if ($nic) {
        $target = "$devLL%$($nic.InterfaceIndex)"
        $cur = ""
        try { $cur = (Get-Content $NcmFile -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
        if ($cur -ne $target) {
            Set-Content -Path $NcmFile -Value $target -Encoding ascii
            Log "dial target updated: $target (restart SteamVR to adopt if it was running)"
        }
    }

    # M7 selector: the core drops this marker when the in-headset menu
    # applies settings that need a SteamVR restart. We orchestrate it.
    # ROBUST restart (the old m4-run path left SteamVR half-dead: dashboard,
    # no compositor, nothing in the headset - a partial kill trips safe-mode
    # which silently blocks our driver, and re-running m4-run raced its own
    # app launch): comprehensive kill -> wait for death -> clear safe-mode ->
    # relaunch the way Steam itself does. NCM stays armed and the app keeps
    # running across a SteamVR-only restart, so the steady-state loop below
    # reconnects everything without our help.
    # user starts SteamVR, so there is no wire for a Control message - Apply
    # 90 Hz / 1.0x, hit Apply "many times", and the PC never heard about it).
    # The client now drops the request in its EXTERNAL files dir, which plain
    # adb can read. We translate it into the same knob files + marker the wire
    # path produces, so both routes converge on one proven restart mechanism.
    # This handler HARD-KILLS a running SteamVR, so it must never fire twice for
    # one request: guard on staleness (age, measured device-side to dodge clock
    # skew) and on delete-confirmation, and skip if the file survives the rm.
    $bridge = "/sdcard/Android/data/$AppId/files/apply.txt"
    $bridgeRaw = ""
    try { $bridgeRaw = (& $Adb -s $Serial shell "cat $bridge 2>/dev/null" 2>$null | Select-Object -First 1) } catch {}
    # an older client's two-field request still applies instead of being ignored.
    if ($bridgeRaw -and ($bridgeRaw -match '^\s*(\d+)\s+(\d+)(?:\s+(\d+))?')) {
        $bHz = [int]$Matches[1]; $bDx = [int]$Matches[2]
        $bPl = 0
        if ($Matches[3]) { $bPl = [int]$Matches[3] }
        # Age of the request, entirely in DEVICE time (mtime vs device now).
        $ageSec = 0
        try {
            $t = & $Adb -s $Serial shell "echo `$(date +%s) `$(stat -c %Y $bridge 2>/dev/null)" 2>$null | Select-Object -First 1
            if ($t -match '^\s*(\d+)\s+(\d+)') { $ageSec = [int]$Matches[1] - [int]$Matches[2] }
        } catch {}
        # Consume FIRST: a malformed or stale request must not loop forever.
        & $Adb -s $Serial shell "rm -f $bridge" 2>$null | Out-Null
        $stillThere = ""
        try { $stillThere = (& $Adb -s $Serial shell "cat $bridge 2>/dev/null" 2>$null | Select-Object -First 1) } catch {}

        if ($stillThere) {
            # Could not consume it. Acting anyway would re-fire (and re-kill
            # SteamVR) every 5 s for as long as the file persists.
            Log "in-headset apply SKIPPED - could not delete $bridge (would loop)"
        } elseif ($ageSec -gt 600) {
            # e.g. Apply pressed with the PC off, then the watcher starts at
            # logon days later - do not launch SteamVR out of nowhere.
            Log "in-headset apply DISCARDED (stale by $ageSec s): $bHz Hz, dx10=$bDx"
        } elseif (($bHz -in 72,80,90,120) -and $bDx -ge 10 -and $bDx -le 20) {
            $res = "{0}.{1}" -f [math]::Floor($bDx / 10), ($bDx % 10)
            Set-Content -Path "$DriverBin\yoinked_refresh.txt" -Value $bHz -Encoding ascii
            Set-Content -Path "$DriverBin\yoinked_stream_res.txt" -Value $res -Encoding ascii
            $pacing = "unchanged"
            if ($bPl -eq 2 -or $bPl -eq 3) {
                Set-Content -Path "$DriverBin\yoinked_pipeline.txt" -Value $bPl -Encoding ascii
                if ($bPl -eq 2) { $pacing = "FAST" } else { $pacing = "SMOOTH" }
            }
            Log "in-headset apply (pre-launch): $bHz Hz, ${res}x, pacing $pacing - knobs written"
            # Hand off to the marker handler below (start or restart SteamVR).
            Set-Content -Path $ApplyFile -Value "$bHz $bDx" -Encoding ascii
        } else {
            Log "in-headset apply IGNORED (out of range): hz=$bHz dx10=$bDx"
        }
    }

    if (Test-Path $ApplyFile) {
        $req = ""
        try { $req = (Get-Content $ApplyFile -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
        Remove-Item $ApplyFile -Force -ErrorAction SilentlyContinue
        # marker) and the pre-launch bridge above. When SteamVR is not running
        # the taskkill is a harmless no-op and vrstartup just starts it fresh.
        if (Get-Process -Name vrserver -ErrorAction SilentlyContinue) {
            Log "apply request ($req) - restarting SteamVR"
        } else {
            Log "apply request ($req) - SteamVR not running, starting it"
        }
        & taskkill /F /IM vrmonitor.exe /IM vrserver.exe /IM vrcompositor.exe /IM vrdashboard.exe /IM vrwebhelper.exe /IM vrstartup.exe /IM vrservicebridge.exe /IM steamtours.exe 2>$null | Out-Null
        for ($k = 0; $k -lt 20; $k++) {
            if (-not (Get-Process -Name vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 500
        }
        Start-Sleep -Seconds 2
        # Clear the safe-mode block an abrupt kill trips (D-M1) or SteamVR
        # starts but silently blocks our driver = black headset.
        $vrCfg = 'C:\Program Files (x86)\Steam\config\steamvr.vrsettings'
        try {
            if (Test-Path $vrCfg) {
                $j = Get-Content $vrCfg -Raw | ConvertFrom-Json
                if ($j.PSObject.Properties['driver_yoinked'] -and $j.driver_yoinked.PSObject.Properties['blocked_by_safe_mode']) {
                    $j.driver_yoinked.blocked_by_safe_mode = $false
                    ($j | ConvertTo-Json -Depth 12) | Set-Content -Encoding utf8 $vrCfg
                    Log "cleared safe-mode block on driver_yoinked"
                }
            }
        } catch { Log "safe-mode clear failed: $_" }
        # Launch via vrstartup.exe (the proven full-compositor start m3-run
        # uses; the steam:// URL can half-start from a background process).
        $vrStartup = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\vrstartup.exe'
        if (Test-Path $vrStartup) {
            Start-Process $vrStartup -ErrorAction SilentlyContinue
            Log "apply done - SteamVR relaunched via vrstartup (loop reconnects app + NCM)"
        } else {
            Log "apply FAILED - vrstartup.exe not found at $vrStartup"
        }
    }

    # Appliance auto-launch: bring Yoinked up whenever the headset is AWAKE
    # (worn) so "put the headset on -> Yoinked is there", showing the please-
    # start-SteamVR prompt until the stream is up. The always-on PC watcher IS
    # the launcher - no Quest launcher-role or boot-receiver hack, no reboot.
    # Launch ONCE per wake so a deliberate close sticks, BUT always (re)launch
    # while vrserver is up (starting SteamVR = a clear intent to play).
    # mWakefulness flips Asleep<->Awake with the proximity/on-head sensor.
    $awake = $false
    try {
        $wf = & $Adb -s $Serial shell "dumpsys power | grep -m1 mWakefulness" 2>$null
        if (($wf -join " ") -match "mWakefulness=Awake") { $awake = $true }
    } catch {}
    if (-not $awake) {
        $launchedThisWake = $false
    } elseif (((Get-Date) - $lastAppStart).TotalSeconds -gt 15) {
        $appPid = & $Adb -s $Serial shell pidof $AppId 2>$null
        $vrUp = [bool](Get-Process -Name vrserver -ErrorAction SilentlyContinue)
        # having to spend a USB round trip to find out.
        $script:appWasRunning = [bool]$appPid
        if ($appPid) {
            $launchedThisWake = $true
        } elseif ((-not $launchedThisWake) -or $vrUp) {
            $lastAppStart = Get-Date
            $launchedThisWake = $true
            if ($vrUp) { Log "headset awake + app dead (SteamVR up) - launching Yoinked" }
            else { Log "headset awake + app dead (SteamVR off) - launching Yoinked (prompts to start SteamVR)" }
            & $Adb -s $Serial shell am start -n $AppActivity 2>$null | Out-Null
        }
    }

    Start-Sleep -Seconds 5
}
