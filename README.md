# Pad Pilot

Pad Pilot is a lightweight, native Windows controller-to-mouse utility built with C++20, Win32, SDL3, and `SendInput`. It starts inactive, works from the notification area, supports mapped SDL gamepads plus a generic joystick fallback, and never requires controller-hiding drivers.

## Download

**Do not use GitHub's `Source code (zip)` download.** That is source code, not the Windows app.

Download the portable Windows build here:

[PadPilot_v1_0_Portable.zip](https://github.com/Neo664evr/PadPilot/raw/main/releases/PadPilot_v1_0_Portable.zip)

Extract it, then run `PadPilot_v1_0.exe`. Keep `SDL3.dll` beside the EXE.

## Default controls

| Controller input | Action |
|---|---|
| Left stick | Move cursor |
| Right stick | Vertical and horizontal scroll |
| RT / R2 | Left mouse button |
| LT / L2 | Right mouse button |
| LB / L1 | Mouse Back |
| RB / R1 | Mouse Forward |
| X / Square | Copy (`Ctrl+C`) |
| A / Cross | Paste (`Ctrl+V`) |

Cursor speed, scroll speed, and dead-zone settings are available in the main window and saved under `%LOCALAPPDATA%\\PadPilot\\`.

## Build

Install CMake, a C++20 MinGW-w64 toolchain, and the SDL3 development package. Then run:

```powershell
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

Place the matching 64-bit `SDL3.dll` beside `PadPilot_v1_0.exe` for distribution.

## License

Pad Pilot is released under the MIT License. SDL3 and the supplemental SDL GameController database retain their own licenses; see `THIRD_PARTY_NOTICES.md`.
