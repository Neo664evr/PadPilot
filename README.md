# PadPilot

Turn your game controller into a lightweight mouse and keyboard for Windows.

## Features

- Controller-controlled mouse movement
- Vertical and horizontal scrolling
- Left and right click support
- Browser back and forward controls
- Copy and paste shortcuts
- Adjustable cursor speed, scroll speed, and dead zone
- Xbox, PlayStation, and generic controller support through SDL3
- Portable Windows app with no installer required

## Download

Download the latest portable build from the [Releases page](https://github.com/Neo664evr/PadPilot/releases/latest).

Extract the ZIP, keep `SDL3.dll` beside the executable, and run `PadPilot_v1_0.exe`.

## Default Controls

| Controller input | Action |
|---|---|
| Left stick | Move cursor |
| Right stick | Scroll vertically and horizontally |
| RT / R2 | Left click |
| LT / L2 | Right click |
| LB / L1 | Back |
| RB / R1 | Forward |
| X / Square | Copy (`Ctrl+C`) |
| A / Cross | Paste (`Ctrl+V`) |

Settings are saved under `%LOCALAPPDATA%\PadPilot\`.

## Build From Source

PadPilot is built with C++20, Win32, SDL3, CMake, Ninja, and `SendInput`.

```powershell
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

## License

PadPilot is released under the MIT License. SDL3 and the supplemental SDL GameController database retain their own licenses. See `THIRD_PARTY_NOTICES.md` for details.
