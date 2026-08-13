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

That's it. Start SteamVR, put the headset on.

---

## Settings

They're inside the headset. **Left grip + menu** opens the overlay. Menu by
itself pauses the game (same as pressing Y).

| | |
|---|---|
| **REFRESH** | 72 / 80 / 90 / 120 Hz |
| **DENSITY** | how sharp — 1.0x to 2.0x |
| **PACING** | **SNAP** / **FAST** / **SMOOTH** |
| **AUTO** | start with the headset |
| **STEAMVR** | opens the SteamVR dashboard |
| **APPLY** | save and restart SteamVR |

Hit **APPLY** and it sticks. Next morning you don't have to put it all back.

Point at a row and pull the trigger. The stick still works.

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

The old overlay chord was **Y + B + both triggers**. That was way too easy to
hit mid-song, so it's gone. Overlay is grip + menu. The SteamVR dashboard is a
button on the overlay — not a hold. A hold used to hitch the compositor for
like 90 ms, which in Beat Saber is a miss.

Menu tap actually pauses the game now. On SteamVR Touch that's Y, so we send
Y. Opening the Steam overlay just to pause was a workaround, not the design.

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

**Menu does nothing.** That's the overlay chord if you're also holding grip.
Menu alone should pause. Y also pauses. SteamVR dashboard is the STEAMVR row,
not the hamburger.

---

## Notes

Windows and NVIDIA only — the video encoder is NVENC and the capture path is
D3D11. On Linux, or on AMD/Intel, use [ALVR](https://github.com/alvr-org/ALVR)
or [WiVRn](https://github.com/WiVRn/WiVRn) instead. They're good.

This is a personal project I use every day, put up in case it's useful to someone
else. No support promised, no roadmap. It may break.

The driver's direct-mode structure follows [ALVR](https://github.com/alvr-org/ALVR)'s,
reimplemented, with thanks — as do the Quest controller grip offsets. Both MIT.
