#pragma once
#include <stdbool.h>

// Fixed-size analysis state, owned exclusively by the render thread.
typedef struct {
    double b0, b1, b2, a1, a2;
    double z1[2], z2[2];
} FaderWeightingStage;

typedef struct {
    FaderWeightingStage shelf, highpass;
    double energy[40], energySum, hopEnergy;
    double gain, targetGain, attackStep, releaseStep, bypassStep;
    unsigned hopFrames, hopCount, windowCount, windowIndex;
    bool enabled;
} FaderLoudnessState;

void FaderLoudnessInit(FaderLoudnessState *state, double sampleRate);
double FaderLoudnessGain(FaderLoudnessState *state, double left, double right, bool enabled);
