// Host tests for common/LGLogic.h. Run by .github/workflows/build.yml before the Theos build:
//   cc -std=c99 -Wall -Wextra -o lg_logic tests/test_logic.c && ./lg_logic
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

#include "../common/LGLogic.h"

static int failures;

static void expectInt(const char *what, int got, int want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %d, want %d\n", what, got, want);
    failures++;
}

static void expectClose(const char *what, double got, double want, double tolerance) {
    if (fabs(got - want) <= tolerance) return;
    fprintf(stderr, "FAIL %s: got %.4f, want %.4f\n", what, got, want);
    failures++;
}

int main(void) {
    expectClose("clamp low", lgClamp(-1.0, 0.0, 1.0), 0.0, 1e-9);
    expectClose("clamp high", lgClamp(2.0, 0.0, 1.0), 1.0, 1e-9);
    expectClose("clamp inside", lgClamp(0.34, 0.0, 1.0), 0.34, 1e-9);

    expectClose("round2 down", lgRound2(0.3449), 0.34, 1e-9);
    expectClose("round2 up", lgRound2(0.3451), 0.35, 1e-9);
    expectClose("round2 integer", lgRound2(46.0), 46.0, 1e-9);
    expectClose("round2 negative", lgRound2(-0.345), -0.35, 1e-9);

    // The page backdrop test: 0.4.19's 70 % rule, and no answer at all without a window height.
    expectInt("page high at 71%", lgIsPageHigh(710.0, 1000.0), 1);
    expectInt("page high at 70%", lgIsPageHigh(700.0, 1000.0), 0);
    expectInt("tile is not page high", lgIsPageHigh(299.0, 1000.0), 0);
    expectInt("no window height", lgIsPageHigh(500.0, 0.0), 0);

    // The crash-loop ladder: three resprings are user action, four are a loop.
    expectInt("3 starts", lgCrashLoopLevel(3), 0);
    expectInt("4 starts", lgCrashLoopLevel(4), 1);
    expectInt("7 starts", lgCrashLoopLevel(7), 1);
    expectInt("8 starts", lgCrashLoopLevel(8), 2);
    expectInt("100 starts", lgCrashLoopLevel(100), 2);

    if (failures) {
        fprintf(stderr, "logic: %d check(s) failed\n", failures);
        return 1;
    }
    puts("logic: all checks passed");
    return 0;
}
