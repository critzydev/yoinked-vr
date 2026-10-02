# ASCII ONLY (PS 5.1 rule).
#
# Choose which Windows output the headset hears.
#
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\yoinked\audio-device.ps1"
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\yoinked\audio-device.ps1" -Name "Headphones"
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\yoinked\audio-device.ps1" -Name default
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\yoinked\audio-device.ps1" -List
#
# yoinked listens to one Windows output (it never changes your default), and
# whatever plays there is what the headset hears. To hear what your own
# headphones hear, pick the output they are plugged into. If you use a mixer
# (Wave Link, Voicemeeter), that is its physical output, not one of its input
# channels, which carry only part of the mix.
#
# The choice is saved in yoinked_audio.txt next to the driver: part of an
# output's name, empty for the Windows default. It takes effect the next time
# SteamVR starts.

param(
    [string]$Name = "",
    [switch]$List      # show the outputs and what is chosen now, change nothing
)

$ErrorActionPreference = 'Stop'

function Ok($t)   { Write-Host "  ok    $t" -ForegroundColor Green }
function Doing($t){ Write-Host "        $t" -ForegroundColor DarkGray }
function Nope($t) { Write-Host "  !!    $t" -ForegroundColor Red }
function Hmm($t)  { Write-Host "  ..    $t" -ForegroundColor Yellow }

$Root = $PSScriptRoot
$file = Join-Path $Root 'driver\yoinked\bin\win64\yoinked_audio.txt'

# Active playback outputs only (render endpoint ids start {0.0.0., inputs {0.0.1.).
$outputs = @(Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'OK' -and $_.InstanceId -match '\{0\.0\.0\.' } |
    ForEach-Object { $_.FriendlyName } | Sort-Object -Unique)

$current = ''
if (Test-Path $file) { $current = ([IO.File]::ReadAllText($file)).Trim() }

function Show-Current {
    if (-not $current -or $current -eq 'default') {
        Doing "now: Windows default output"
    } else {
        $hit = @($outputs | Where-Object { $_.ToLower().Contains($current.ToLower()) })
        if ($hit.Count) { Doing "now: $($hit[0])" }
        else { Hmm "now: '$current' matches no output, so the Windows default is used" }
    }
}

if ($List -or -not $Name) {
    Write-Host ""
    Write-Host "  Which output should the headset hear?" -ForegroundColor Cyan
    Show-Current
    Write-Host ""
    for ($i = 0; $i -lt $outputs.Count; $i++) { Write-Host ("  {0,2}  {1}" -f ($i + 1), $outputs[$i]) }
    Write-Host "   0  Windows default output"
    Write-Host ""
    if ($List) { return }
    $pick = Read-Host "  number (Enter keeps what you have)"
    if ($pick -notmatch '^\d+$' -or [int]$pick -gt $outputs.Count) { Doing "nothing changed"; return }
    $Name = if ([int]$pick -eq 0) { 'default' } else { $outputs[[int]$pick - 1] }
}

if ($Name -ne 'default') {
    $hit = @($outputs | Where-Object { $_.ToLower().Contains($Name.ToLower()) })
    if ($hit.Count -eq 0) { Nope "no output matches '$Name' - nothing changed"; return }
    if ($hit.Count -gt 1) { Hmm "'$Name' matches several outputs ($($hit -join '; ')) - yoinked will use whichever it finds first. Give more of the name to pick one." }
}

# Saved as UTF-8 without a BOM, so a name with accents survives and still matches.
$value = $Name
if ($Name -eq 'default') { $value = '' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
[IO.File]::WriteAllText($file, "$value`r`n", (New-Object System.Text.UTF8Encoding($false)))
if ($Name -eq 'default') { Ok "headset audio: Windows default output" } else { Ok "headset audio: $Name" }
Doing "restart SteamVR to apply"
