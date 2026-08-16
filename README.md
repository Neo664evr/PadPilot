# PadPilot

PadPilot turns a game controller into a lightweight mouse and keyboard for Windows.

It is a small, native C++20 utility for people who want controller-based cursor control, scrolling, clicking, and common keyboard shortcuts without a heavyweight background suite.

## Features

- Controller-controlled mouse movement
- Vertical and horizontal scrolling
- Left and right click support
- Browser back and forward controls
- Copy and paste shortcuts
- Adjustable cursor speed, scroll speed, and dead zone
- Xbox, PlayStation, and generic controller support through SDL3
- Portable Windows app with no installer required
- Local settings stored under `%LOCALAPPDATA%\\PadPilot\\`

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

## Project status

PadPilot is an actively maintained open-source Windows utility. The current focus is improving input reliability, preventing stuck-button states, refining controller mappings, and making portable releases easier to install and test.

If you use PadPilot, please report the controller model, Windows version, and exact steps when opening an issue. Reproducible reports are especially useful for fixing device-specific behavior.

## Roadmap

- Improve controller reconnect and disconnect handling
- Add clearer in-app mapping feedback
- Expand tested controller coverage
- Add automated build and test validation
- Publish clearer release notes for each portable build

Feature requests and bug reports are welcome through [GitHub Issues](https://github.com/Neo664evr/PadPilot/issues).

## Build From Source

PadPilot is built with C++20, Win32, SDL3, CMake, Ninja, and `SendInput`.

```powershell
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

## License

PadPilot is released under the MIT License. SDL3 and the supplemental SDL GameController database retain their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
