# obs-audio-tweaks

Two small OBS Lua scripts for PipeWire/WirePlumber that make **EasyEffects → OBS → Zoom/Teams/Chrome** routing reliable.

**Intended chain:**

```
Real mic → EasyEffects → easyeffects_source → OBS Mic/Aux → OBS Monitor → OBS_Virtual_Output_Audio_As_Mic_For_Apps → OBS_Virtual_Output_Audio_As_Mic_For_Chrome → Zoom/Teams
```

---

## Problems they solve

1. **Hot mic when EasyEffects crashes.** Without a guard, `OBS Mic/Aux` (pointing at `easyeffects_source`) stays unmuted on a dead source or falls back to raw capture. You leak unprocessed audio.

2. **PipeWire locks the OBS capture stream.** `node.dont-reconnect` + WirePlumber `restore-stream` prevents moving `Mic/Aux` between `easyeffects_source` and hardware. This breaks EasyEffects' per-app `Activer` toggle and makes switching OBS back to the raw mic unreliable (see [wwmm/easyeffects#4955](https://github.com/wwmm/easyeffects/issues/4955)).

3. **OBS monitoring goes to the wrong device.** OBS resets `Monitoring Device` to `Default` on profile switch. With `Monitor and Output` set, the final mix goes to your headphones instead of the virtual sink that apps use as mic — so Zoom hears silence.

4. **Virtual devices disappear on reboot.** `pactl load-module module-null-sink` is transient. Without a persistent `pipewire-pulse.conf.d` file you recreate them manually every boot, and `pavucontrol` can't wire `monitor → playback` for local listening.

---

## Scripts

### `obs-easyeffects.lua` — Mic guard + movable-capture fix

- Polls `easyeffects_source` via `pactl get-source-mute` (default 500ms). If missing → mutes `Mic/Aux`; restores only if it owned the mute (tracks UUID, won't clobber your manual mutes).
- On load installs `~/.config/pipewire/pipewire-pulse.conf.d/obs-movable-capture.conf` with `node.dont-reconnect = false` for `obs:Mic/Aux`, so WirePlumber can actually move the stream.

Settings: `Protected OBS source` (default `Mic/Aux`), `EasyEffects source` (default `easyeffects_source`), `Poll interval` 100–5000ms.

### `obs-virtual-audio.lua` — Persistent virtual sink/mic + monitoring

- Creates `~/.config/pipewire/pipewire-pulse.conf.d/obs-virtual-audio.conf` (null-sink `OBS_Virtual_Output_Audio_As_Mic_For_Apps` + remap-source `OBS_Virtual_Output_Audio_As_Mic_For_Chrome`) and loads them for the current session if needed.
- Checkbox `Use virtual output as OBS Monitoring Device` syncs **Settings → Audio → Advanced → Monitoring Device** to the virtual sink (and persists it to `basic.ini`).
- Optional `Listen to processed OBS output` wires `monitor_FL/FR → <stereo device>:playback_FL/FR` via `pw-link` so you can hear what Zoom hears.

For sources to appear in the virtual mic, set **Advanced Audio Properties → Audio Monitoring → Monitor and Output**.

---

## Install

```bash
cp obs-*.lua ~/.config/obs-studio/scripts/

systemctl --user restart pipewire pipewire-pulse wireplumber  # if prompted
```

**Requirements:** PipeWire + `pipewire-pulse` + WirePlumber, `pactl` and `pw-link` in PATH, OBS 28+ with Lua, EasyEffects 8.x (guard only).

**Verify:** `pactl list short sinks | grep OBS_Virtual` and `pw-link -l | grep OBS_Virtual` should show the sink, its `monitor`, and the Chrome source.

In Zoom/Teams/Chrome, select mic **`OBS_Virtual_Output_Audio_As_Mic_For_Apps/OBS_Virtual_Output_Audio_As_Mic_For_Chrome`** — not the raw hardware mic.
