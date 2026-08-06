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

It'll set everything up and tell you when to plug the headset in.

You need: **Windows**, an **NVIDIA GPU**, **SteamVR** installed, a **Quest 3**,
and a **USB 3 cable**.

Your headset also needs Developer Mode turned on — Meta Horizon phone app → your
headset → Headset Settings → Developer Mode. The installer waits for you at that
step, so you can do it then.

That's it. Start SteamVR, put the headset on.

---

## Settings

They're inside the headset. Press **Y + B + both triggers**.

| | |
|---|---|
| **REFRESH** | 72 / 80 / 90 / 120 Hz |
| **DENSITY** | how sharp — 1.0x to 2.0x |
| **PACING** | **FAST** or **SMOOTH** |
| **AUTO** | start with the headset |
| **APPLY** | save and restart SteamVR |

**PACING** is worth knowing about. It's how long the headset waits before showing
a frame, which is the trade between latency and steadiness:

- **FAST** — lowest latency. Best for rhythm games where you need your hands to
  feel instant.
- **SMOOTH** — about 8 ms more latency, but rock-steady frame delivery. Better
  for anything with a lot of camera movement.

Try both. They feel genuinely different.

If 120 Hz doesn't stick, your headset may need it enabled in its own settings
first, or your cable may not be USB 3.

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
| `yoinked_pipeline.txt` | same as PACING — `2` fast, `3` smooth |
| `yoinked_foveate.txt` | `1` keeps the centre sharp and compresses the edges. `0` for uniform |
| `yoinked_pack.txt` | `1` encodes both eyes in one pass. Faster. `0` for separate |
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

---

## Notes

Windows and NVIDIA only — the video encoder is NVENC and the capture path is
D3D11. On Linux, or on AMD/Intel, use [ALVR](https://github.com/alvr-org/ALVR)
or [WiVRn](https://github.com/WiVRn/WiVRn) instead. They're good.

This is a personal project I use every day, put up in case it's useful to someone
else. No support promised, no roadmap. It may break.

The driver's direct-mode structure follows [ALVR](https://github.com/alvr-org/ALVR)'s,
reimplemented, with thanks — as do the Quest controller grip offsets. Both MIT.
