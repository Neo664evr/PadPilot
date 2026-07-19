#pragma once
#include <algorithm>
#include <cmath>

namespace cm {

struct Vec2 { double x{}, y{}; };

inline Vec2 radialDeadZone(double x, double y, double dead = 0.14) {
    const double mag = std::sqrt(x * x + y * y);
    if (mag <= dead || mag == 0.0) return {};
    const double norm = std::min(1.0, (mag - dead) / (1.0 - dead));
    return { x / mag * norm, y / mag * norm };
}

inline double speedCurve(double magnitude) {
    magnitude = std::clamp(magnitude, 0.0, 1.0);
    return 75.0 * magnitude + 2850.0 * std::pow(magnitude, 2.15);
}

struct FractionalAccumulator {
    double value{};
    int add(double amount) {
        value += amount;
        const int whole = value >= 0.0 ? static_cast<int>(std::floor(value))
                                       : static_cast<int>(std::ceil(value));
        value -= whole;
        return whole;
    }
    void clear() { value = 0.0; }
};

struct EdgeButton {
    bool held{};
    int update(bool now) {
        if (now == held) return 0;
        held = now;
        return now ? 1 : -1;
    }
    int release() { return update(false); }
};

inline bool thresholdWithHysteresis(double value, bool held,
                                    double press = 0.35, double release = 0.25) {
    return held ? value > release : value > press;
}

} // namespace cm
