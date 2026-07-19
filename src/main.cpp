#define _WIN32_WINNT 0x0A00
#define SDL_MAIN_HANDLED
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wtsapi32.h>
#include <mmsystem.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>
#include "core.hpp"

constexpr wchar_t kClassName[] = L"PadPilotWindow";
constexpr wchar_t kMutexName[] = L"Local\\PadPilot.SingleInstance";
constexpr UINT WM_SHOW_EXISTING = WM_APP + 1;
constexpr UINT WM_TRAY = WM_APP + 2;
constexpr UINT_PTR TIMER_INPUT = 1;
constexpr int ID_DEVICE = 100;
constexpr int ID_ACTIVATE = 101;
constexpr int ID_MOUSE_SPEED = 102;
constexpr int ID_SCROLL_SPEED = 103;
constexpr int ID_DEAD_ZONE = 104;
constexpr int ID_TRAY_SHOW = 200;
constexpr int ID_TRAY_TOGGLE = 201;
constexpr int ID_TRAY_EXIT = 202;
constexpr UINT IDI_APP = 1;

struct DeviceInfo {
    SDL_JoystickID id{};
    std::string guid;
    std::wstring name;
    bool gamepad{};
};

struct GenericMap {
    int lx{-1}, ly{-1}, rx{-1}, ry{-1};
    int ltAxis{-1}, rtAxis{-1}, ltButton{-1}, rtButton{-1};
    int lb{-1}, rb{-1}, copyButton{-1}, pasteButton{-1};
    int ltBase{}, rtBase{}, ltSign{1}, rtSign{1};
    bool valid() const { return lx >= 0 && ly >= 0 && rx >= 0 && ry >= 0 && lb >= 0 && rb >= 0 && copyButton >= 0 && pasteButton >= 0 && (ltAxis >= 0 || ltButton >= 0) && (rtAxis >= 0 || rtButton >= 0); }
};

struct LiveInput {
    double lx{}, ly{}, rx{}, ry{}, lt{}, rt{};
    bool lb{}, rb{}, copy{}, paste{};
};

HINSTANCE g_instance{};
HWND g_window{}, g_combo{}, g_button{}, g_mouseSlider{}, g_scrollSlider{}, g_deadZoneSlider{};
HICON g_icon{};
NOTIFYICONDATAW g_tray{};
std::vector<DeviceInfo> g_devices;
std::string g_selectedGuid;
SDL_JoystickID g_selectedId{};
SDL_Gamepad* g_gamepad{};
SDL_Joystick* g_joystick{};
GenericMap g_map;
LiveInput g_live;
std::vector<int> g_axisBase;
std::vector<int> g_axisPeak;
std::vector<bool> g_prevRawButtons;
int g_wizardStage{-1};
ULONGLONG g_wizardCooldown{};
bool g_wizardAwaitNeutral{};
bool g_active{}, g_exiting{}, g_timerResolution{};
bool g_inputError{};
int g_mouseSensitivity{100}, g_scrollSensitivity{100}, g_deadZonePercent{14};
std::wstring g_configPath;
LARGE_INTEGER g_qpcFreq{}, g_lastQpc{};
cm::FractionalAccumulator g_moveX, g_moveY, g_scrollX, g_scrollY;
cm::EdgeButton g_left, g_right, g_back, g_forward, g_copy, g_paste;
ULONGLONG g_lastScan{};

std::wstring widen(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(static_cast<size_t>(std::max(1, n)), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    if (!w.empty() && w.back() == L'\0') w.pop_back();
    return w;
}

std::string guidString(SDL_GUID guid) {
    char text[33]{};
    SDL_GUIDToString(guid, text, static_cast<int>(sizeof(text)));
    return text;
}

void buildConfigPath() {
    wchar_t base[MAX_PATH]{};
    SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, SHGFP_TYPE_CURRENT, base);
    std::wstring dir = std::wstring(base) + L"\\PadPilot";
    CreateDirectoryW(dir.c_str(), nullptr);
    g_configPath = dir + L"\\settings.ini";
    if (GetFileAttributesW(g_configPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        std::wstring oldPath = std::wstring(base) + L"\\ControllerMouse\\settings.ini";
        CopyFileW(oldPath.c_str(), g_configPath.c_str(), TRUE);
    }
}

void writeIni(const wchar_t* section, const wchar_t* key, const std::wstring& value) {
    WritePrivateProfileStringW(section, key, value.c_str(), g_configPath.c_str());
}

int readInt(const std::wstring& section, const wchar_t* key, int fallback = -1) {
    return static_cast<int>(GetPrivateProfileIntW(section.c_str(), key, fallback, g_configPath.c_str()));
}

void saveSelected() { writeIni(L"settings", L"selected_guid", widen(g_selectedGuid)); }

void saveSensitivity() {
    writeIni(L"settings", L"mouse_speed", std::to_wstring(g_mouseSensitivity));
    writeIni(L"settings", L"scroll_speed", std::to_wstring(g_scrollSensitivity));
    writeIni(L"settings", L"dead_zone", std::to_wstring(g_deadZonePercent));
}

std::wstring mapSection() { return L"mapping." + widen(g_selectedGuid); }

void saveMap() {
    const std::wstring s = mapSection();
    auto put = [&](const wchar_t* key, int v) { writeIni(s.c_str(), key, std::to_wstring(v)); };
    put(L"lx", g_map.lx); put(L"ly", g_map.ly); put(L"rx", g_map.rx); put(L"ry", g_map.ry);
    put(L"lt_axis", g_map.ltAxis); put(L"rt_axis", g_map.rtAxis);
    put(L"lt_button", g_map.ltButton); put(L"rt_button", g_map.rtButton);
    put(L"lb", g_map.lb); put(L"rb", g_map.rb);
    put(L"copy_button", g_map.copyButton); put(L"paste_button", g_map.pasteButton);
    put(L"lt_base", g_map.ltBase); put(L"rt_base", g_map.rtBase);
    put(L"lt_sign", g_map.ltSign); put(L"rt_sign", g_map.rtSign);
    put(L"complete", 1);
}

bool loadMap() {
    const std::wstring s = mapSection();
    if (readInt(s, L"complete", 0) != 1) return false;
    g_map.lx = readInt(s, L"lx"); g_map.ly = readInt(s, L"ly");
    g_map.rx = readInt(s, L"rx"); g_map.ry = readInt(s, L"ry");
    g_map.ltAxis = readInt(s, L"lt_axis"); g_map.rtAxis = readInt(s, L"rt_axis");
    g_map.ltButton = readInt(s, L"lt_button"); g_map.rtButton = readInt(s, L"rt_button");
    g_map.lb = readInt(s, L"lb"); g_map.rb = readInt(s, L"rb");
    g_map.copyButton = readInt(s, L"copy_button", 2); g_map.pasteButton = readInt(s, L"paste_button", 0);
    g_map.ltBase = readInt(s, L"lt_base", 0); g_map.rtBase = readInt(s, L"rt_base", 0);
    g_map.ltSign = readInt(s, L"lt_sign", 1); g_map.rtSign = readInt(s, L"rt_sign", 1);
    return g_map.valid();
}

void sendMouse(DWORD flags, LONG data = 0, LONG dx = 0, LONG dy = 0) {
    INPUT in{}; in.type = INPUT_MOUSE; in.mi.dwFlags = flags; in.mi.mouseData = static_cast<DWORD>(data); in.mi.dx = dx; in.mi.dy = dy;
    if (SendInput(1, &in, sizeof(in)) != 1 && g_active) g_inputError = true;
}

void applyEdge(cm::EdgeButton& edge, bool now, DWORD down, DWORD up, LONG data = 0) {
    int change = edge.update(now);
    if (change == 1) sendMouse(down, data);
    else if (change == -1) sendMouse(up, data);
}

void sendShortcut(WORD key) {
    const bool ctrlAlreadyDown = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
    INPUT inputs[4]{}; int count = 0;
    auto add = [&](WORD vk, DWORD flags) { inputs[count].type = INPUT_KEYBOARD; inputs[count].ki.wVk = vk; inputs[count].ki.dwFlags = flags; ++count; };
    if (!ctrlAlreadyDown) add(VK_CONTROL, 0);
    add(key, 0); add(key, KEYEVENTF_KEYUP);
    if (!ctrlAlreadyDown) add(VK_CONTROL, KEYEVENTF_KEYUP);
    if (SendInput(count, inputs, sizeof(INPUT)) != static_cast<UINT>(count) && g_active) g_inputError = true;
}

void releaseAll() {
    if (g_left.release() == -1) sendMouse(MOUSEEVENTF_LEFTUP);
    if (g_right.release() == -1) sendMouse(MOUSEEVENTF_RIGHTUP);
    if (g_back.release() == -1) sendMouse(MOUSEEVENTF_XUP, XBUTTON1);
    if (g_forward.release() == -1) sendMouse(MOUSEEVENTF_XUP, XBUTTON2);
    g_copy.release(); g_paste.release();
    g_moveX.clear(); g_moveY.clear(); g_scrollX.clear(); g_scrollY.clear();
}

void updateTray();

void setActive(bool active) {
    const bool ready = g_joystick && (g_gamepad || g_map.valid()) && g_wizardStage < 0;
    if (active && !ready) return;
    if (!active) releaseAll();
    if (!active) g_inputError = false;
    if (g_active == active) return;
    g_active = active;
    if (active && !g_timerResolution) { timeBeginPeriod(1); g_timerResolution = true; QueryPerformanceCounter(&g_lastQpc); }
    if (!active && g_timerResolution) { timeEndPeriod(1); g_timerResolution = false; }
    if (g_window) SetTimer(g_window, TIMER_INPUT, active ? 5 : 16, nullptr);
    SetWindowTextW(g_button, active ? L"Deactivate" : L"Activate");
    updateTray();
    InvalidateRect(g_window, nullptr, FALSE);
}

void closeSelected() {
    setActive(false);
    if (g_gamepad) SDL_CloseGamepad(g_gamepad);
    else if (g_joystick) SDL_CloseJoystick(g_joystick);
    g_gamepad = nullptr; g_joystick = nullptr; g_selectedId = 0; g_map = {};
    g_wizardStage = -1; g_live = {};
}

bool autoMapGeneric() {
    const int axes = SDL_GetNumJoystickAxes(g_joystick);
    const int buttons = SDL_GetNumJoystickButtons(g_joystick);
    std::vector<int> centered, other;
    for (int i = 0; i < axes; ++i) {
        const int v = SDL_GetJoystickAxis(g_joystick, i);
        if (std::abs(v) < 9000) centered.push_back(i); else other.push_back(i);
    }
    if (centered.size() < 4 || buttons < 6) return false;
    g_map.lx = centered[0]; g_map.ly = centered[1]; g_map.rx = centered[2]; g_map.ry = centered[3];
    g_map.lb = 4; g_map.rb = 5; g_map.copyButton = 2; g_map.pasteButton = 0;
    std::vector<int> triggerAxes;
    for (int i : other) triggerAxes.push_back(i);
    for (int i : centered) if (i != g_map.lx && i != g_map.ly && i != g_map.rx && i != g_map.ry) triggerAxes.push_back(i);
    if (triggerAxes.size() >= 2) {
        g_map.ltAxis = triggerAxes[0]; g_map.rtAxis = triggerAxes[1];
        g_map.ltBase = SDL_GetJoystickAxis(g_joystick, g_map.ltAxis);
        g_map.rtBase = SDL_GetJoystickAxis(g_joystick, g_map.rtAxis);
    } else if (buttons >= 8) {
        g_map.ltButton = 6; g_map.rtButton = 7;
    } else return false;
    return g_map.valid();
}

void beginWizard() {
    g_wizardStage = 0; g_wizardCooldown = GetTickCount64() + 500;
    g_wizardAwaitNeutral = false;
    const int axes = SDL_GetNumJoystickAxes(g_joystick);
    const int buttons = SDL_GetNumJoystickButtons(g_joystick);
    g_axisBase.resize(axes); g_axisPeak.assign(axes, 0); g_prevRawButtons.resize(buttons);
    for (int i = 0; i < axes; ++i) g_axisBase[i] = SDL_GetJoystickAxis(g_joystick, i);
    for (int i = 0; i < buttons; ++i) g_prevRawButtons[i] = SDL_GetJoystickButton(g_joystick, i);
}

void openSelected(SDL_JoystickID id) {
    closeSelected();
    g_selectedId = id;
    if (SDL_IsGamepad(id)) {
        g_gamepad = SDL_OpenGamepad(id);
        if (g_gamepad) g_joystick = SDL_GetGamepadJoystick(g_gamepad);
    } else g_joystick = SDL_OpenJoystick(id);
    if (!g_joystick) { g_selectedId = 0; return; }
    if (!g_gamepad) {
        if (!loadMap()) {
            if (autoMapGeneric()) saveMap(); else beginWizard();
        }
    }
    QueryPerformanceCounter(&g_lastQpc);
    updateTray();
    InvalidateRect(g_window, nullptr, FALSE);
}

void selectDeviceIndex(int index) {
    if (index < 0 || index >= static_cast<int>(g_devices.size())) return;
    g_selectedGuid = g_devices[index].guid; saveSelected();
    openSelected(g_devices[index].id);
}

void scanDevices(bool force = false) {
    ULONGLONG now = GetTickCount64();
    if (!force && now - g_lastScan < 750) return;
    g_lastScan = now;
    int count{}; SDL_JoystickID* ids = SDL_GetJoysticks(&count);
    std::vector<DeviceInfo> next;
    for (int i = 0; i < count; ++i) {
        DeviceInfo d; d.id = ids[i]; d.gamepad = SDL_IsGamepad(ids[i]);
        d.guid = guidString(SDL_GetJoystickGUIDForID(ids[i]));
        const char* n = d.gamepad ? SDL_GetGamepadNameForID(ids[i]) : SDL_GetJoystickNameForID(ids[i]);
        d.name = widen(n ? n : "Controller");
        next.push_back(std::move(d));
    }
    SDL_free(ids);
    bool same = next.size() == g_devices.size();
    if (same) for (size_t i = 0; i < next.size(); ++i) if (next[i].id != g_devices[i].id || next[i].name != g_devices[i].name) { same = false; break; }
    bool currentPresent = false;
    for (auto& d : next) if (d.id == g_selectedId) currentPresent = true;
    if (g_selectedId && !currentPresent) closeSelected();
    g_devices = std::move(next);
    if (!same) {
        SendMessageW(g_combo, CB_RESETCONTENT, 0, 0);
        for (auto& d : g_devices) SendMessageW(g_combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(d.name.c_str()));
    }
    int chosen = -1;
    if (g_selectedId) for (size_t i = 0; i < g_devices.size(); ++i) if (g_devices[i].id == g_selectedId) chosen = static_cast<int>(i);
    if (chosen < 0 && !g_selectedGuid.empty()) for (size_t i = 0; i < g_devices.size(); ++i) if (g_devices[i].guid == g_selectedGuid) { chosen = static_cast<int>(i); break; }
    if (chosen < 0 && g_selectedGuid.empty() && !g_devices.empty()) chosen = 0;
    if (chosen >= 0) {
        SendMessageW(g_combo, CB_SETCURSEL, chosen, 0);
        if (!g_joystick) {
            g_selectedGuid = g_devices[chosen].guid; saveSelected(); openSelected(g_devices[chosen].id);
        }
    } else SendMessageW(g_combo, CB_SETCURSEL, -1, 0);
    EnableWindow(g_combo, !g_devices.empty());
    EnableWindow(g_button, g_joystick && (g_gamepad || g_map.valid()) && g_wizardStage < 0);
    updateTray(); InvalidateRect(g_window, nullptr, FALSE);
}

double axisNorm(Sint16 v) { return std::clamp(v < 0 ? v / 32768.0 : v / 32767.0, -1.0, 1.0); }

double genericTrigger(int axis, int button, int base, int sign) {
    if (button >= 0) return SDL_GetJoystickButton(g_joystick, button) ? 1.0 : 0.0;
    if (axis < 0) return 0.0;
    const int v = SDL_GetJoystickAxis(g_joystick, axis);
    const double denom = sign > 0 ? (32767.0 - base) : (base + 32768.0);
    if (denom < 1000) return 0.0;
    return std::clamp(((v - base) * sign) / denom, 0.0, 1.0);
}

void readLive() {
    if (!g_joystick) { g_live = {}; return; }
    if (g_gamepad) {
        g_live.lx = axisNorm(SDL_GetGamepadAxis(g_gamepad, SDL_GAMEPAD_AXIS_LEFTX));
        g_live.ly = axisNorm(SDL_GetGamepadAxis(g_gamepad, SDL_GAMEPAD_AXIS_LEFTY));
        g_live.rx = axisNorm(SDL_GetGamepadAxis(g_gamepad, SDL_GAMEPAD_AXIS_RIGHTX));
        g_live.ry = axisNorm(SDL_GetGamepadAxis(g_gamepad, SDL_GAMEPAD_AXIS_RIGHTY));
        g_live.lt = std::clamp(SDL_GetGamepadAxis(g_gamepad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) / 32767.0, 0.0, 1.0);
        g_live.rt = std::clamp(SDL_GetGamepadAxis(g_gamepad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) / 32767.0, 0.0, 1.0);
        g_live.lb = SDL_GetGamepadButton(g_gamepad, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER);
        g_live.rb = SDL_GetGamepadButton(g_gamepad, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER);
        g_live.copy = SDL_GetGamepadButton(g_gamepad, SDL_GAMEPAD_BUTTON_WEST);
        g_live.paste = SDL_GetGamepadButton(g_gamepad, SDL_GAMEPAD_BUTTON_SOUTH);
    } else if (g_map.valid()) {
        g_live.lx = axisNorm(SDL_GetJoystickAxis(g_joystick, g_map.lx)); g_live.ly = axisNorm(SDL_GetJoystickAxis(g_joystick, g_map.ly));
        g_live.rx = axisNorm(SDL_GetJoystickAxis(g_joystick, g_map.rx)); g_live.ry = axisNorm(SDL_GetJoystickAxis(g_joystick, g_map.ry));
        g_live.lt = genericTrigger(g_map.ltAxis, g_map.ltButton, g_map.ltBase, g_map.ltSign);
        g_live.rt = genericTrigger(g_map.rtAxis, g_map.rtButton, g_map.rtBase, g_map.rtSign);
        g_live.lb = SDL_GetJoystickButton(g_joystick, g_map.lb); g_live.rb = SDL_GetJoystickButton(g_joystick, g_map.rb);
        g_live.copy = SDL_GetJoystickButton(g_joystick, g_map.copyButton); g_live.paste = SDL_GetJoystickButton(g_joystick, g_map.pasteButton);
    } else {
        int axes = SDL_GetNumJoystickAxes(g_joystick);
        if (axes > 0) g_live.lx = axisNorm(SDL_GetJoystickAxis(g_joystick, 0));
        if (axes > 1) g_live.ly = axisNorm(SDL_GetJoystickAxis(g_joystick, 1));
        if (axes > 2) g_live.rx = axisNorm(SDL_GetJoystickAxis(g_joystick, 2));
        if (axes > 3) g_live.ry = axisNorm(SDL_GetJoystickAxis(g_joystick, 3));
    }
}

void wizardTick() {
    if (g_wizardStage < 0 || !g_joystick || GetTickCount64() < g_wizardCooldown) return;
    int axes = SDL_GetNumJoystickAxes(g_joystick), buttons = SDL_GetNumJoystickButtons(g_joystick);
    if (g_wizardAwaitNeutral) {
        bool neutral = true;
        for (int i = 0; i < axes; ++i) if (std::abs(static_cast<int>(SDL_GetJoystickAxis(g_joystick, i)) - g_axisBase[i]) > 6000) neutral = false;
        for (int i = 0; i < buttons; ++i) if (SDL_GetJoystickButton(g_joystick, i)) neutral = false;
        if (!neutral) return;
        for (int i = 0; i < axes; ++i) g_axisBase[i] = SDL_GetJoystickAxis(g_joystick, i);
        std::fill(g_axisPeak.begin(), g_axisPeak.end(), 0);
        for (int i = 0; i < buttons; ++i) g_prevRawButtons[i] = false;
        g_wizardAwaitNeutral = false;
    }
    for (int i = 0; i < axes; ++i) g_axisPeak[i] = std::max(g_axisPeak[i], std::abs(static_cast<int>(SDL_GetJoystickAxis(g_joystick, i)) - g_axisBase[i]));
    auto reset = [&] { std::fill(g_axisPeak.begin(), g_axisPeak.end(), 0); g_wizardAwaitNeutral = true; g_wizardCooldown = GetTickCount64() + 450; InvalidateRect(g_window, nullptr, FALSE); };
    if (g_wizardStage <= 1) {
        std::vector<int> order(axes); for (int i = 0; i < axes; ++i) order[i] = i;
        std::sort(order.begin(), order.end(), [&](int a, int b) { return g_axisPeak[a] > g_axisPeak[b]; });
        if (order.size() >= 2 && g_axisPeak[order[1]] > 15000) {
            int first = std::min(order[0], order[1]), second = std::max(order[0], order[1]);
            if (g_wizardStage == 0) { g_map.lx = first; g_map.ly = second; }
            else { g_map.rx = first; g_map.ry = second; }
            ++g_wizardStage; reset();
        }
        return;
    }
    if (g_wizardStage <= 3) {
        int best = -1, amount = 0;
        for (int i = 0; i < axes; ++i) {
            if (i == g_map.lx || i == g_map.ly || i == g_map.rx || i == g_map.ry || i == g_map.ltAxis) continue;
            if (g_axisPeak[i] > amount) { amount = g_axisPeak[i]; best = i; }
        }
        int pressed = -1;
        for (int i = 0; i < buttons; ++i) { bool now = SDL_GetJoystickButton(g_joystick, i); if (now && !g_prevRawButtons[i]) pressed = i; g_prevRawButtons[i] = now; }
        if (best >= 0 && amount > 14000) {
            int now = SDL_GetJoystickAxis(g_joystick, best), base = g_axisBase[best], sign = now >= base ? 1 : -1;
            if (g_wizardStage == 2) { g_map.ltAxis = best; g_map.ltBase = base; g_map.ltSign = sign; }
            else { g_map.rtAxis = best; g_map.rtBase = base; g_map.rtSign = sign; }
            ++g_wizardStage; reset();
        } else if (pressed >= 0) {
            if (g_wizardStage == 2) g_map.ltButton = pressed; else g_map.rtButton = pressed;
            ++g_wizardStage; reset();
        }
        return;
    }
    for (int i = 0; i < buttons; ++i) {
        bool now = SDL_GetJoystickButton(g_joystick, i);
        if (now && !g_prevRawButtons[i]) {
            if (g_wizardStage == 4) g_map.lb = i;
            else if (g_wizardStage == 5) g_map.rb = i;
            else if (g_wizardStage == 6) g_map.copyButton = i;
            else g_map.pasteButton = i;
            ++g_wizardStage; reset();
            if (g_wizardStage >= 8) { g_wizardStage = -1; saveMap(); EnableWindow(g_button, TRUE); }
            break;
        }
        g_prevRawButtons[i] = now;
    }
}

void processInput() {
    SDL_PumpEvents(); scanDevices(); wizardTick(); readLive();
    LARGE_INTEGER now{}; QueryPerformanceCounter(&now);
    double dt = (now.QuadPart - g_lastQpc.QuadPart) / static_cast<double>(g_qpcFreq.QuadPart);
    g_lastQpc = now; dt = std::clamp(dt, 0.001, 0.032);
    if (!g_active) { releaseAll(); InvalidateRect(g_window, nullptr, FALSE); return; }
    if (!g_joystick || (!g_gamepad && !g_map.valid())) { setActive(false); return; }
    auto move = cm::radialDeadZone(g_live.lx, g_live.ly, g_deadZonePercent / 100.0);
    double mag = std::min(1.0, std::sqrt(move.x * move.x + move.y * move.y));
    if (mag > 0) {
        double speed = cm::speedCurve(mag) * (g_mouseSensitivity / 100.0);
        int dx = g_moveX.add((move.x / mag) * speed * dt), dy = g_moveY.add((move.y / mag) * speed * dt);
        if (dx || dy) sendMouse(MOUSEEVENTF_MOVE, 0, dx, dy);
    }
    auto scroll = cm::radialDeadZone(g_live.rx, g_live.ry, g_deadZonePercent / 100.0);
    auto scrollAmount = [&](double v) { return std::copysign(1440.0 * (g_scrollSensitivity / 100.0) * std::pow(std::abs(v), 1.45) * dt, v); };
    int vy = g_scrollY.add(scrollAmount(-scroll.y)); if (vy) sendMouse(MOUSEEVENTF_WHEEL, vy);
    int hx = g_scrollX.add(scrollAmount(scroll.x)); if (hx) sendMouse(MOUSEEVENTF_HWHEEL, hx);
    bool leftNow = cm::thresholdWithHysteresis(g_live.rt, g_left.held);
    bool rightNow = cm::thresholdWithHysteresis(g_live.lt, g_right.held);
    applyEdge(g_left, leftNow, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
    applyEdge(g_right, rightNow, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
    applyEdge(g_back, g_live.lb, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, XBUTTON1);
    applyEdge(g_forward, g_live.rb, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, XBUTTON2);
    if (g_copy.update(g_live.copy) == 1) sendShortcut('C');
    if (g_paste.update(g_live.paste) == 1) sendShortcut('V');
    if (g_inputError) { g_inputError = false; setActive(false); }
    InvalidateRect(g_window, nullptr, FALSE);
}

void loadSupplementalMappings() {
    HRSRC res = FindResourceW(g_instance, MAKEINTRESOURCEW(101), RT_RCDATA);
    if (!res) return;
    HGLOBAL mem = LoadResource(g_instance, res); const char* data = static_cast<const char*>(LockResource(mem)); DWORD size = SizeofResource(g_instance, res);
    std::string line;
    for (DWORD i = 0; i <= size; ++i) {
        char c = i < size ? data[i] : '\n';
        if (c == '\n' || c == '\r') {
            if (!line.empty() && line[0] != '#' && line.size() > 32) {
                char guidText[33]{}; memcpy(guidText, line.data(), 32); SDL_GUID guid = SDL_StringToGUID(guidText);
                char* existing = SDL_GetGamepadMappingForGUID(guid);
                if (!existing) SDL_AddGamepadMapping(line.c_str()); else SDL_free(existing);
            }
            line.clear();
        } else line.push_back(c);
    }
}

void updateTray() {
    if (!g_tray.cbSize) return;
    const wchar_t* state = !g_joystick ? L"Pad Pilot — Controller Disconnected" : (g_active ? L"Pad Pilot — Active" : L"Pad Pilot — Inactive");
    wcsncpy_s(g_tray.szTip, state, _TRUNCATE);
    g_tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    Shell_NotifyIconW(NIM_MODIFY, &g_tray);
}

void showWindow() { ShowWindow(g_window, SW_RESTORE); SetForegroundWindow(g_window); }

void trayMenu() {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, ID_TRAY_SHOW, L"Show");
    AppendMenuW(menu, MF_STRING | ((!g_joystick) ? MF_GRAYED : 0), ID_TRAY_TOGGLE, g_active ? L"Deactivate" : L"Activate");
    AppendMenuW(menu, MF_STRING, ID_TRAY_EXIT, L"Exit");
    POINT pt{}; GetCursorPos(&pt); SetForegroundWindow(g_window);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN, pt.x, pt.y, 0, g_window, nullptr);
    DestroyMenu(menu);
}

void drawText(HDC dc, int x, int y, const wchar_t* text, COLORREF color, int size = 16, int weight = FW_NORMAL) {
    HFONT font = CreateFontW(-MulDiv(size, GetDeviceCaps(dc, LOGPIXELSY), 72), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    HFONT old = static_cast<HFONT>(SelectObject(dc, font)); SetTextColor(dc, color); SetBkMode(dc, TRANSPARENT); TextOutW(dc, x, y, text, static_cast<int>(wcslen(text))); SelectObject(dc, old); DeleteObject(font);
}

void paint(HWND hwnd) {
    PAINTSTRUCT ps{}; HDC target = BeginPaint(hwnd, &ps); RECT client{}; GetClientRect(hwnd, &client);
    HDC dc = CreateCompatibleDC(target);
    HBITMAP bitmap = CreateCompatibleBitmap(target, client.right, client.bottom);
    HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
    HBRUSH bg = CreateSolidBrush(RGB(20, 23, 30)); FillRect(dc, &client, bg); DeleteObject(bg);
    drawText(dc, 28, 22, L"Pad Pilot", RGB(239, 242, 248), 25, FW_SEMIBOLD);
    COLORREF statusColor = !g_joystick ? RGB(150, 83, 91) : (g_active ? RGB(63, 209, 125) : RGB(235, 78, 91));
    const wchar_t* status = !g_joystick ? L"CONTROLLER DISCONNECTED" : (g_active ? L"ACTIVE" : L"INACTIVE");
    HBRUSH dot = CreateSolidBrush(statusColor); HGDIOBJ oldBrush = SelectObject(dc, dot); Ellipse(dc, 590, 31, 606, 47); SelectObject(dc, oldBrush); DeleteObject(dot);
    drawText(dc, 615, 26, status, statusColor, 12, FW_BOLD);
    drawText(dc, 28, 77, L"CONTROLLER", RGB(136, 145, 162), 10, FW_BOLD);

    RECT body{40, 150, 390, 365}; HBRUSH bodyBrush = CreateSolidBrush(RGB(40, 45, 56)); HPEN outline = CreatePen(PS_SOLID, 2, RGB(68, 76, 91));
    HGDIOBJ ob = SelectObject(dc, bodyBrush), op = SelectObject(dc, outline); RoundRect(dc, body.left, body.top, body.right, body.bottom, 70, 70);
    SelectObject(dc, ob); SelectObject(dc, op); DeleteObject(bodyBrush); DeleteObject(outline);
    auto stick = [&](int cx, int cy, double x, double y, const wchar_t* label) {
        HBRUSH ring = CreateSolidBrush(RGB(22, 25, 32)); HGDIOBJ old = SelectObject(dc, ring); Ellipse(dc, cx-35, cy-35, cx+35, cy+35); SelectObject(dc, old); DeleteObject(ring);
        int px = cx + static_cast<int>(x*18), py = cy + static_cast<int>(y*18); HBRUSH cap = CreateSolidBrush(RGB(91, 104, 127)); old = SelectObject(dc, cap); Ellipse(dc, px-20, py-20, px+20, py+20); SelectObject(dc, old); DeleteObject(cap);
        drawText(dc, cx-22, cy+43, label, RGB(166, 174, 190), 10, FW_BOLD);
    };
    stick(128, 258, g_live.lx, g_live.ly, L"MOVE"); stick(282, 284, g_live.rx, g_live.ry, L"SCROLL");
    auto shoulder = [&](int x, int y, int w, const wchar_t* text, bool on) { RECT r{x,y,x+w,y+30}; HBRUSH b=CreateSolidBrush(on?RGB(72,185,119):RGB(65,72,86)); FillRect(dc,&r,b); DeleteObject(b); drawText(dc,x+10,y+6,text,RGB(240,243,248),10,FW_BOLD); };
    shoulder(62, 157, 75, L"LB / L1", g_live.lb); shoulder(283, 157, 75, L"RB / R1", g_live.rb);
    shoulder(143, 166, 62, L"LT / L2", g_live.lt>.25); shoulder(215, 166, 62, L"RT / R2", g_live.rt>.25);
    auto faceButton = [&](int cx, int cy, const wchar_t* text, bool on) { HBRUSH b=CreateSolidBrush(on?RGB(72,185,119):RGB(65,72,86)); HGDIOBJ old=SelectObject(dc,b); Ellipse(dc,cx-17,cy-17,cx+17,cy+17); SelectObject(dc,old); DeleteObject(b); drawText(dc,cx-6,cy-9,text,RGB(240,243,248),11,FW_BOLD); };
    faceButton(330, 221, L"X", g_live.copy); faceButton(362, 251, L"A", g_live.paste);

    drawText(dc, 430, 148, L"FIXED CONTROLS", RGB(136,145,162), 10, FW_BOLD);
    const wchar_t* rows[] = {L"Left stick    Move cursor", L"Right stick   Scroll", L"RT / R2       Left click", L"LT / L2       Right click", L"LB / L1       Mouse Back", L"RB / R1       Mouse Forward", L"X / Square    Copy  (Ctrl+C)", L"A / Cross     Paste  (Ctrl+V)"};
    for (int i=0;i<8;++i) drawText(dc,430,174+i*25,rows[i],RGB(224,228,236),11,i>=2?FW_SEMIBOLD:FW_NORMAL);
    drawText(dc, 28, 384, L"SENSITIVITY", RGB(136,145,162), 10, FW_BOLD);
    std::wstring mouseLabel = L"Cursor speed   " + std::to_wstring(g_mouseSensitivity) + L"%";
    std::wstring scrollLabel = L"Scroll speed   " + std::to_wstring(g_scrollSensitivity) + L"%";
    std::wstring deadLabel = L"Dead zone   " + std::to_wstring(g_deadZonePercent) + L"%";
    drawText(dc, 28, 407, mouseLabel.c_str(), RGB(224,228,236), 11, FW_SEMIBOLD);
    drawText(dc, 255, 407, scrollLabel.c_str(), RGB(224,228,236), 11, FW_SEMIBOLD);
    drawText(dc, 482, 407, deadLabel.c_str(), RGB(224,228,236), 11, FW_SEMIBOLD);
    if (g_wizardStage >= 0) {
        const wchar_t* prompts[] = {L"Move the LEFT STICK in a circle", L"Move the RIGHT STICK in a circle", L"Press the LEFT TRIGGER", L"Press the RIGHT TRIGGER", L"Press LB / L1", L"Press RB / R1", L"Press X / Square for Copy", L"Press A / Cross for Paste"};
        RECT box{30, 475, 690, 519}; HBRUSH b=CreateSolidBrush(RGB(53,42,26)); FillRect(dc,&box,b); DeleteObject(b);
        drawText(dc,48,486,prompts[std::clamp(g_wizardStage,0,7)],RGB(255,196,96),14,FW_BOLD);
    }
    BitBlt(target, 0, 0, client.right, client.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, oldBitmap); DeleteObject(bitmap); DeleteDC(dc);
    EndPaint(hwnd, &ps);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_combo = CreateWindowExW(0, WC_COMBOBOXW, L"", WS_CHILD|WS_VISIBLE|CBS_DROPDOWNLIST|WS_VSCROLL, 28, 98, 662, 220, hwnd, reinterpret_cast<HMENU>(ID_DEVICE), g_instance, nullptr);
        SendMessageW(g_combo, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
        auto makeSlider = [&](int id, int x, int minValue, int maxValue, int value) {
            HWND slider = CreateWindowExW(0, TRACKBAR_CLASSW, L"", WS_CHILD|WS_VISIBLE|TBS_HORZ|TBS_NOTICKS, x, 430, 200, 32, hwnd, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), g_instance, nullptr);
            SendMessageW(slider, TBM_SETRANGE, TRUE, MAKELONG(minValue, maxValue));
            SendMessageW(slider, TBM_SETPOS, TRUE, value);
            return slider;
        };
        g_mouseSlider = makeSlider(ID_MOUSE_SPEED, 28, 25, 200, g_mouseSensitivity);
        g_scrollSlider = makeSlider(ID_SCROLL_SPEED, 255, 25, 200, g_scrollSensitivity);
        g_deadZoneSlider = makeSlider(ID_DEAD_ZONE, 482, 5, 30, g_deadZonePercent);
        g_button = CreateWindowExW(0, WC_BUTTONW, L"Activate", WS_CHILD|WS_VISIBLE|BS_OWNERDRAW, 255, 540, 210, 52, hwnd, reinterpret_cast<HMENU>(ID_ACTIVATE), g_instance, nullptr);
        g_tray.cbSize=sizeof(g_tray); g_tray.hWnd=hwnd; g_tray.uID=1; g_tray.uCallbackMessage=WM_TRAY; g_tray.hIcon=g_icon; g_tray.uFlags=NIF_MESSAGE|NIF_ICON|NIF_TIP; wcscpy_s(g_tray.szTip,L"Pad Pilot — Controller Disconnected"); Shell_NotifyIconW(NIM_ADD,&g_tray); g_tray.uVersion=NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION,&g_tray);
        WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION); SetTimer(hwnd,TIMER_INPUT,16,nullptr); scanDevices(true); return 0;
    }
    case WM_TIMER: if (wp==TIMER_INPUT) processInput(); return 0;
    case WM_HSCROLL: {
        HWND source = reinterpret_cast<HWND>(lp);
        if (source == g_mouseSlider) g_mouseSensitivity = static_cast<int>(SendMessageW(source, TBM_GETPOS, 0, 0));
        else if (source == g_scrollSlider) g_scrollSensitivity = static_cast<int>(SendMessageW(source, TBM_GETPOS, 0, 0));
        else if (source == g_deadZoneSlider) g_deadZonePercent = static_cast<int>(SendMessageW(source, TBM_GETPOS, 0, 0));
        else break;
        saveSensitivity(); InvalidateRect(hwnd, nullptr, FALSE); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wp)==ID_ACTIVATE && HIWORD(wp)==BN_CLICKED) setActive(!g_active);
        else if (LOWORD(wp)==ID_DEVICE && HIWORD(wp)==CBN_SELCHANGE) selectDeviceIndex(static_cast<int>(SendMessageW(g_combo,CB_GETCURSEL,0,0)));
        else if (LOWORD(wp)==ID_TRAY_SHOW) showWindow();
        else if (LOWORD(wp)==ID_TRAY_TOGGLE) setActive(!g_active);
        else if (LOWORD(wp)==ID_TRAY_EXIT) { g_exiting=true; DestroyWindow(hwnd); }
        return 0;
    case WM_DRAWITEM: {
        auto* di=reinterpret_cast<DRAWITEMSTRUCT*>(lp); if(di->CtlID==ID_ACTIVATE){ HBRUSH b=CreateSolidBrush(g_active?RGB(46,157,96):RGB(200,57,70)); FillRect(di->hDC,&di->rcItem,b); DeleteObject(b); SetTextColor(di->hDC,RGB(255,255,255)); SetBkMode(di->hDC,TRANSPARENT); HFONT f=CreateFontW(-20,0,0,0,FW_BOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI"); auto old=SelectObject(di->hDC,f); DrawTextW(di->hDC,g_active?L"Deactivate":L"Activate",-1,&di->rcItem,DT_CENTER|DT_VCENTER|DT_SINGLELINE); SelectObject(di->hDC,old); DeleteObject(f); return TRUE;} break;
    }
    case WM_CTLCOLORLISTBOX: case WM_CTLCOLORSTATIC: case WM_CTLCOLOREDIT: { HDC dc=reinterpret_cast<HDC>(wp); SetTextColor(dc,RGB(235,238,245)); SetBkColor(dc,RGB(35,39,48)); static HBRUSH b=CreateSolidBrush(RGB(35,39,48)); return reinterpret_cast<LRESULT>(b); }
    case WM_PAINT: paint(hwnd); return 0;
    case WM_ERASEBKGND: return 1;
    case WM_CLOSE: ShowWindow(hwnd,SW_HIDE); return 0;
    case WM_SHOW_EXISTING: showWindow(); return 0;
    case WM_TRAY: if (LOWORD(lp)==WM_LBUTTONDBLCLK) showWindow(); else if (LOWORD(lp)==WM_CONTEXTMENU || LOWORD(lp)==WM_RBUTTONUP) trayMenu(); return 0;
    case WM_POWERBROADCAST:
        if (wp==PBT_APMSUSPEND) setActive(false); else if (wp==PBT_APMRESUMEAUTOMATIC || wp==PBT_APMRESUMESUSPEND) { g_lastScan=0; scanDevices(true); }
        return TRUE;
    case WM_DEVICECHANGE: g_lastScan=0; scanDevices(true); return 0;
    case WM_WTSSESSION_CHANGE: if (wp==WTS_SESSION_LOCK || wp==WTS_SESSION_LOGOFF) setActive(false); else { g_lastScan=0; scanDevices(true); } return 0;
    case WM_QUERYENDSESSION: setActive(false); return TRUE;
    case WM_DESTROY:
        KillTimer(hwnd,TIMER_INPUT); setActive(false); closeSelected(); WTSUnRegisterSessionNotification(hwnd); Shell_NotifyIconW(NIM_DELETE,&g_tray); g_tray.cbSize=0; SDL_Quit(); PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
    HANDLE mutex=CreateMutexW(nullptr,TRUE,kMutexName);
    if (!mutex || GetLastError()==ERROR_ALREADY_EXISTS) { HWND existing=FindWindowW(kClassName,nullptr); if(existing) PostMessageW(existing,WM_SHOW_EXISTING,0,0); if(mutex) CloseHandle(mutex); return 0; }
    g_instance=instance; SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); QueryPerformanceFrequency(&g_qpcFreq); QueryPerformanceCounter(&g_lastQpc); buildConfigPath();
    g_mouseSensitivity = std::clamp(readInt(L"settings", L"mouse_speed", 100), 25, 200);
    g_scrollSensitivity = std::clamp(readInt(L"settings", L"scroll_speed", 100), 25, 200);
    g_deadZonePercent = std::clamp(readInt(L"settings", L"dead_zone", 14), 5, 30);
    wchar_t saved[64]{}; GetPrivateProfileStringW(L"settings",L"selected_guid",L"",saved,64,g_configPath.c_str());
    int bytes=WideCharToMultiByte(CP_UTF8,0,saved,-1,nullptr,0,nullptr,nullptr); if(bytes>1){ g_selectedGuid.resize(bytes); WideCharToMultiByte(CP_UTF8,0,saved,-1,g_selectedGuid.data(),bytes,nullptr,nullptr); g_selectedGuid.pop_back(); }
    SDL_SetMainReady(); SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI,"1");
    if (!SDL_Init(SDL_INIT_GAMEPAD)) { MessageBoxW(nullptr,widen(std::string("SDL initialization failed: ")+SDL_GetError()).c_str(),L"Pad Pilot",MB_ICONERROR); CloseHandle(mutex); return 1; }
    loadSupplementalMappings(); InitCommonControls(); g_icon=LoadIconW(instance,MAKEINTRESOURCEW(IDI_APP)); if(!g_icon) g_icon=LoadIconW(nullptr,IDI_APPLICATION);
    WNDCLASSEXW wc{}; wc.cbSize=sizeof(wc); wc.lpfnWndProc=WindowProc; wc.hInstance=instance; wc.hIcon=g_icon; wc.hIconSm=g_icon; wc.hCursor=LoadCursorW(nullptr,IDC_ARROW); wc.lpszClassName=kClassName; wc.hbrBackground=reinterpret_cast<HBRUSH>(COLOR_WINDOW+1); RegisterClassExW(&wc);
    RECT r{0,0,720,620}; AdjustWindowRectExForDpi(&r,WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX,FALSE,0,GetDpiForSystem());
    g_window=CreateWindowExW(0,kClassName,L"Pad Pilot",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX,CW_USEDEFAULT,CW_USEDEFAULT,r.right-r.left,r.bottom-r.top,nullptr,nullptr,instance,nullptr);
    if(!g_window){ SDL_Quit(); CloseHandle(mutex); return 1; }
    ShowWindow(g_window,show); UpdateWindow(g_window); MSG msg{}; while(GetMessageW(&msg,nullptr,0,0)>0){ TranslateMessage(&msg); DispatchMessageW(&msg); }
    if(g_timerResolution) timeEndPeriod(1);
    ReleaseMutex(mutex); CloseHandle(mutex); return static_cast<int>(msg.wParam);
}
