# yoinked

Plug your Quest 3 into your PC and play SteamVR games. No Link, no Air Link, no
Virtual Desktop.

It starts itself when you put the headset on.

---

## Install

Paste this into **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/critzydev/yoinked-vr/main/install.ps1 | iex
```

It'll set everything up and tell you when to plug the headset in. Running it
again later just updates you — it never overwrites settings you've already
tuned.

You need: **Windows**, an **NVIDIA GPU**, **SteamVR** installed, a **Quest 3**,
and a **USB 3 cable**.

Your headset also needs Developer Mode turned on — Meta Horizon phone app → your
headset → Headset Settings → Developer Mode. The installer waits for you at that
step, so you can do it then.

It also asks what the headset should hear — pick whatever you normally listen
on. To change it later, paste this into PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\yoinked\audio-device.ps1"
```

That's it. Start SteamVR, put the headset on.

---

## Settings

They're on a watch on your left wrist. **Hold the left menu button** for half a
second and it shows up. A quick tap still pauses the game — the game never sees
the hold.

Press the face to open it (left trigger while you look at it). Grab the bezel
with your right hand and twist to pick:

| | |
|---|---|
| **STEAM** | opens the SteamVR dashboard |
| **SETUP** | the settings below |
| **EXIT** | closes SteamVR. The headset stays in the lobby |

STEAM and EXIT want two presses, so you don't hit them by accident.

In **SETUP**, twist to a row and press to change it:

| | |
|---|---|
| **HZ** | 72 / 80 / 90 / 120 |
| **X** | how sharp — 1.0x to 2.0x |
| **PACING** | **SNAP** / **FAST** / **SMOOTH** |
| **AUTO** | start with the headset |
| **DONE** | save. Restarts SteamVR if you changed something |

It sticks. Next morning you don't have to put it all back.

Menu or B puts the watch away.

**PACING** is how long the headset waits before showing a frame:

- **SNAP** — show it as soon as it arrives. For rhythm games. A bit more
  sensitive if the cable hiccups.
- **FAST** — the default. Hands feel like Link.
- **SMOOTH** — waits a little longer, but rock-steady. Better if the camera
  moves a lot.

Try them. They feel different.

There's a quiet lobby while SteamVR isn't up yet. Controllers, a floor, that's
it.

If 120 Hz doesn't stick, your headset may need it enabled in its own settings
first, or your cable may not be USB 3.

---

## Lately

Settings moved to the wrist watch. The flat overlay is gone.

The PC now locks its frame timing to the headset's, so every frame lands on the
tick it was made for. No more slow drift into a stutter every few minutes.

About 3 ms less delay between the PC and your eyes. The headset does less work
per frame, and that comes straight off the wait.

Controllers are predicted by the headset's own tracking instead of SteamVR's
straight-line guess. It sees the swing turning. `yoinked_predict.txt` → `0` if
you want the old way back.

SteamVR popups (chaperone, notifications) used to blank an eye for a split
second. They're drawn over the game now.

Video rides UDP. If a USB packet vanishes you lose a frame, not the whole
stream for a third of a second.

---

## Tuning

Everything else is one small text file per setting, in:

```
%LOCALAPPDATA%\yoinked\driver\yoinked\bin\win64\
```

Edit one, restart SteamVR. The useful ones:

| file | what it does |
|---|---|
| `yoinked_bitrate.txt` | Mbps **per eye**. Higher is sharper. Too high and you get stutters |
| `yoinked_pipeline.txt` | same as PACING — `1` snap, `2` fast, `3` smooth |
| `yoinked_render_scale.txt` | extra render sharpness. Costs the game GPU, not the encoder. `1.0` default |
| `yoinked_foveate.txt` | `1` keeps the centre sharp and compresses the edges. `0` for uniform |
| `yoinked_pack.txt` | `0` encodes each eye on its own — on GPUs with two encoders (RTX 40) both at once. `1` packs both into one pass |
| `yoinked_predict.txt` | `1` controllers use the headset's prediction. `0` SteamVR's |
| `yoinked_audio.txt` | what the headset hears. Part of a device name; empty = Windows default. `audio-device.ps1` picks it for you |
| `yoinked_refresh.txt` | Hz. Must match what your headset actually granted |

Reinstalling never overwrites these — your tuning survives updates.

---

## If it's not working

**Nothing happens when I start SteamVR.** Check the headset is plugged into a
USB 3 port, and that you accepted the USB debugging prompt inside the headset.
Running the install command again is safe and usually fixes it.

**It's stuttering.** Drop `yoinked_bitrate.txt` by 15 or so and restart SteamVR.
If you're on 120 Hz and it's marginal, 90 Hz is much easier to hold.

**Blurry.** Raise DENSITY in the headset menu, or raise the bitrate.

**Sluggish hands.** Set PACING to FAST.

**Menu does nothing.** A tap pauses. Holding it opens the watch instead, and
the game never sees a hold. Y also pauses. SteamVR dashboard is STEAM on the
watch, not the hamburger.

**Wrong audio, or none.** Run the audio picker from the Install section and pick
the output you're actually listening on, then restart SteamVR.

---

## Notes

Windows and NVIDIA only — the video encoder is NVENC and the capture path is
D3D11. On Linux, or on AMD/Intel, use [ALVR](https://github.com/alvr-org/ALVR)
or [WiVRn](https://github.com/WiVRn/WiVRn) instead. They're good.

This is a personal project I use every day, put up in case it's useful to someone
else. No support promised, no roadmap. It may break.

The driver's direct-mode structure follows [ALVR](https://github.com/alvr-org/ALVR)'s,
reimplemented, with thanks — as do the Quest controller grip offsets. Both MIT.
