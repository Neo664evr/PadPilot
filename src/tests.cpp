#include "core.hpp"
#include <cassert>
#include <cmath>
#include <iostream>

int main() {
    using namespace cm;
    auto z = radialDeadZone(0.05, 0.05); assert(z.x == 0 && z.y == 0);
    auto f = radialDeadZone(1, 0); assert(std::abs(f.x - 1.0) < 1e-9 && f.y == 0);
    auto d = radialDeadZone(.5, .5); assert(std::abs(d.x - d.y) < 1e-9);
    assert(speedCurve(0) == 0); assert(speedCurve(1) > 2800);
    FractionalAccumulator a; assert(a.add(.4) == 0); assert(a.add(.4) == 0); assert(a.add(.4) == 1);
    FractionalAccumulator b; assert(b.add(-.6) == 0); assert(b.add(-.6) == -1);
    EdgeButton e; assert(e.update(false) == 0); assert(e.update(true) == 1);
    assert(e.update(true) == 0); assert(e.release() == -1); assert(e.release() == 0);
    assert(thresholdWithHysteresis(.4, false)); assert(thresholdWithHysteresis(.3, true));
    assert(!thresholdWithHysteresis(.2, true));
    std::cout << "Pad Pilot core tests passed\n";
}
