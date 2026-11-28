// Logic that decides what the look does, with no Foundation and no UIKit in it.
//
// The heuristics in Tweak.m (what counts as a page backdrop, when the crash-loop ladder steps down, how
// a slider value is rounded) were only ever proven by installing a build and looking at the phone. In
// this header they are plain C, and tests/test_logic.c proves them on the build machine in CI.
#ifndef LG_LOGIC_H
#define LG_LOGIC_H

// Sliders store long fractions; the look keeps two decimals so the number in Settings is the number used.
static inline double lgClamp(double value, double low, double high) {
    return value < low ? low : (value > high ? high : value);
}

static inline double lgRound2(double value) {
    double scaled = value * 100.0;
    return (double)((long long)(scaled + (scaled < 0 ? -0.5 : 0.5))) / 100.0;
}

// A material that is as tall as most of the window is the page backdrop the tiles of a page sit on, not
// a tile: glass on it is the extra pane behind a whole page. 0.4.19 settled on 70 %.
#define LG_PAGE_HIGH_RATIO 0.70
static inline int lgIsPageHigh(double height, double windowHeight) {
    return windowHeight > 1.0 && height > windowHeight * LG_PAGE_HIGH_RATIO;
}

// Crash-loop ladder. Three resprings in 90 s are a user respringing; four in a row are a loop, and a loop
// is worth one more try with the risky half (the Metal renderer) left out, because the decor is what a
// screenshot needs. Eight starts is a loop that survives that too: stay stock for the boot.
static inline int lgCrashLoopLevel(long starts) {
    if (starts >= 8) return 2;
    if (starts >= 4) return 1;
    return 0;
}

#endif
