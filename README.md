# KnifeLock

A Cyberpunk 2077 Headshot aim assist for throwing knives and throwing axes.

When you aim with a throwing knife or axe, the mod picks the enemy closest to your crosshair,
keeps locked on that enemy, and steers the camera toward their head.

## Requirements

- Cyberpunk 2077.
- [Cyber Engine Tweaks (CET)](https://www.nexusmods.com/cyberpunk2077/mods/107) installed.
- Redscript is included with the game; no extra installation is needed for the `.reds` file.

## Installation

Copy the folders from this package into the game's root folder (the one containing `bin` and `r6`):

```
Cyberpunk 2077/
├── r6/scripts/KnifeLock/
│   └── KnifeLockAim.reds
└── bin/x64/plugins/cyber_engine_tweaks/mods/KnifeLock/
    └── init.lua
```

Close the game before copying. When it starts, the game compiles the scripts automatically.

## How to use

1. Open the CET overlay (default key: `~`). A window called **KnifeLock** appears.
2. Check **Activate KnifeLock**.
3. Adjust the options if you want:
   - **Max distance**: how far away a target can be, in meters.
   - **View angle**: how far from the center of the crosshair a target can be.
   - **Police**, **Gang members** and **Civilians**: which groups the mod can lock onto.
4. Equip a throwing knife or axe and aim.

Settings are saved automatically to `settings.txt`, in the CET mod folder, and loaded when the game starts.

## Behavior

- The target stays locked while it is alive, not knocked out, within range, and close to the crosshair.
- The mod does not throw for you. You still press the throw button yourself.
- Targets behind walls or not visible are not locked.
- When you stop aiming, the camera returns to normal.
- Only throwing knives and axes are affected. Pistols and other weapons are not changed.

## Limitations

- No auto fire.
- Correction strength, dead zone and rotation limits are fixed in the code (`KnifeLockConfig` in `KnifeLockAim.reds`).
- Not recommended alongside other automatic aim mods, since they may fight over the camera.

## Troubleshooting

- **The menu does not appear:** confirm CET is installed and the mod folder is at `bin/x64/plugins/cyber_engine_tweaks/mods/KnifeLock/`.
- **Redscript compilation error:** check `r6/logs/redscript_rCURRENT.log`. If the message mentions `KnifeLock`, the `.reds` file has a problem.
- **Settings are not saved:** the CET console shows an error message. Make sure the mod folder is writable.
