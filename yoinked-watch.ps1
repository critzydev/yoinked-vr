# ASCII ONLY (PS 5.1 rule).
#
# Hidden at logon. Keeps USB-NCM armed, launches the headset app when you put
# the Quest on, and applies in-headset settings (including a SteamVR restart).

$DriverBin = Join-Path $PSScriptRoot 'driver\yoinked\bin\win64'
$NcmFile = "$DriverBin\yoinked_ncm.txt"
$LogFile = "$DriverBin\yoinked_watch.log"
$ApplyFile = "$DriverBin\yoinked_apply.txt"
$AppId = "com.yoinked.client"
$AppActivity = "com.yoinked.client/android.app.NativeActivity"

function Find-Adb {
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
    )) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

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

$Adb = Find-Adb
$Serial = $null

$mutex = New-Object System.Threading.Mutex($false, 'Global\YoinkedWatchSingleton')
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
$script:appWasRunning = $false
$script:lastStreamCheck = [DateTime]::MinValue

while ($true) {
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

    $nic = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match "UsbNcm|NCM" -and $_.Status -eq "Up" } |
        Select-Object -First 1
    if (-not $nic) {
        if (((Get-Date) - $lastArm).TotalSeconds -gt 60) {
            $lastArm = Get-Date
            Log "usb0 up on the headset but no NCM adapter on this PC - re-arming"
            & $Adb -s $Serial shell svc usb setFunctions ncm 2>$null | Out-Null
            Start-Sleep -Seconds 6
            & $Adb wait-for-device 2>$null | Out-Null
            & $Adb -s $Serial shell cmd ethernet set-ip-configuration usb0 static 192.168.42.2/24 2>$null | Out-Null
            & $Adb -s $Serial reverse tcp:9943 tcp:9943 2>$null | Out-Null
        }
        Start-Sleep -Seconds 5
        continue
    }

    $target = "$devLL%$($nic.InterfaceIndex)"
    $cur = ""
    try { $cur = (Get-Content $NcmFile -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
    if ($cur -ne $target) {
        Set-Content -Path $NcmFile -Value $target -Encoding ascii
        Log "dial target updated: $target"
    }

    $bridge = "/sdcard/Android/data/$AppId/files/apply.txt"
    $bridgeRaw = ""
    try { $bridgeRaw = (& $Adb -s $Serial shell "cat $bridge 2>/dev/null" 2>$null | Select-Object -First 1) } catch {}
    if ($bridgeRaw -and ($bridgeRaw -match '^\s*(\d+)\s+(\d+)(?:\s+(\d+))?')) {
        $bHz = [int]$Matches[1]; $bDx = [int]$Matches[2]
        $bPl = 0
        if ($Matches[3]) { $bPl = [int]$Matches[3] }
        $ageSec = 0
        try {
            $t = & $Adb -s $Serial shell "echo `$(date +%s) `$(stat -c %Y $bridge 2>/dev/null)" 2>$null | Select-Object -First 1
            if ($t -match '^\s*(\d+)\s+(\d+)') { $ageSec = [int]$Matches[1] - [int]$Matches[2] }
        } catch {}
        & $Adb -s $Serial shell "rm -f $bridge" 2>$null | Out-Null
        $stillThere = ""
        try { $stillThere = (& $Adb -s $Serial shell "cat $bridge 2>/dev/null" 2>$null | Select-Object -First 1) } catch {}

        if ($stillThere) {
            Log "in-headset apply SKIPPED - could not delete $bridge (would loop)"
        } elseif ($ageSec -gt 600) {
            Log "in-headset apply DISCARDED (stale by $ageSec s)"
        } elseif (($bHz -in 72,80,90,120) -and $bDx -ge 10 -and $bDx -le 20) {
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
    }

    if (Test-Path $ApplyFile) {
        $req = ""
        try { $req = (Get-Content $ApplyFile -ErrorAction SilentlyContinue | Select-Object -First 1) } catch {}
        Remove-Item $ApplyFile -Force -ErrorAction SilentlyContinue
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
        $vrStartup = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\vrstartup.exe'
        if (Test-Path $vrStartup) {
            Start-Process $vrStartup -ErrorAction SilentlyContinue
            Log "apply done - SteamVR relaunched"
        } else {
            Log "apply FAILED - vrstartup.exe not found"
        }
    }

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
        $script:appWasRunning = [bool]$appPid
        if ($appPid) {
            $launchedThisWake = $true
        } elseif ((-not $launchedThisWake) -or $vrUp) {
            $lastAppStart = Get-Date
            $launchedThisWake = $true
            Log "headset awake + app dead - launching Yoinked"
            & $Adb -s $Serial shell am start -n $AppActivity 2>$null | Out-Null
        }
    }

    Start-Sleep -Seconds 5
}
