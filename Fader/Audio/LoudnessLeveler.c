#include "LoudnessLeveler.h"
#include <math.h>
#include <string.h>

// ITU-R BS.1770, Annex 1, Tables 1–2 provide the 48 kHz K-weighting
// coefficients. They are used ONLY to measure level; playback is not filtered.
// https://www.itu.int/rec/R-REC-BS.1770
// Re-map the reference transfer function through the bilinear transform to
// retain its analog response at the device's actual sample rate.
static FaderWeightingStage weighting(double b0, double b1, double b2,
                                     double a1, double a2, double sampleRate) {
    double r = sampleRate / 48000;
    double n0 = b0 + b1 + b2, n1 = 2*r*(b0-b2), n2 = r*r*(b0-b1+b2);
    double d0 = 1 + a1 + a2, d1 = 2*r*(1-a2), d2 = r*r*(1-a1+a2);
    double norm = d0 + d1 + d2;
    return (FaderWeightingStage){
        .b0 = (n0+n1+n2)/norm, .b1 = 2*(n0-n2)/norm, .b2 = (n0-n1+n2)/norm,
        .a1 = 2*(d0-d2)/norm, .a2 = (d0-d1+d2)/norm
    };
}

void FaderLoudnessInit(FaderLoudnessState *s, double sampleRate) {
    memset(s, 0, sizeof(*s));
    s->shelf = weighting(1.53512485958697, -2.69169618940638, 1.19839281085285,
                        -1.69065929318241, .73248077421585, sampleRate);
    s->highpass = weighting(1, -2, 1, -1.99004745483398, .99007225036621, sampleRate);
    s->hopFrames = (unsigned)llround(sampleRate * .010);
    s->attackStep = -expm1(-1 / (sampleRate * .080));
    s->releaseStep = -expm1(-1 / (sampleRate * .750));
    s->bypassStep = -expm1(-1 / (sampleRate * .030));
    s->gain = s->targetGain = 1;
}

static double weighted(FaderWeightingStage *s, double input, unsigned channel) {
    double output = s->b0 * input + s->z1[channel];
    s->z1[channel] = s->b1 * input - s->a1 * output + s->z2[channel];
    s->z2[channel] = s->b2 * input - s->a2 * output;
    // Prevent denormal arithmetic after long silence.
    if (fabs(s->z1[channel]) < 1e-20) s->z1[channel] = 0;
    if (fabs(s->z2[channel]) < 1e-20) s->z2[channel] = 0;
    return output;
}

static void resetAnalysis(FaderLoudnessState *s) {
    memset(s->shelf.z1, 0, sizeof(s->shelf.z1));
    memset(s->shelf.z2, 0, sizeof(s->shelf.z2));
    memset(s->highpass.z1, 0, sizeof(s->highpass.z1));
    memset(s->highpass.z2, 0, sizeof(s->highpass.z2));
    memset(s->energy, 0, sizeof(s->energy));
    s->energySum = s->hopEnergy = 0;
    s->hopCount = s->windowCount = s->windowIndex = 0;
    s->targetGain = 1;
}

double FaderLoudnessGain(FaderLoudnessState *s, double left, double right, bool enabled) {
    if (enabled != s->enabled) {
        resetAnalysis(s);
        s->enabled = enabled;
    }
    if (!enabled && s->gain == 1) return 1;
    if (enabled) {
        // Square channels separately so opposite-phase stereo never cancels
        // the detector and triggers an erroneous boost.
        // Bound detector input so a corrupt oversized sample cannot poison the
        // rolling sum through catastrophic cancellation after the sample ages out.
        double a = weighted(&s->highpass, weighted(&s->shelf, fmin(1, fmax(-1, left)), 0), 0);
        double b = weighted(&s->highpass, weighted(&s->shelf, fmin(1, fmax(-1, right)), 1), 1);
        s->hopEnergy += a*a + b*b;
        if (++s->hopCount == s->hopFrames) {
            double energy = s->hopEnergy / s->hopFrames;
            s->energySum += energy - s->energy[s->windowIndex];
            s->energy[s->windowIndex] = energy;
            s->windowIndex = (s->windowIndex + 1) % 40;
            if (s->windowCount < 40) s->windowCount++;
            // Wait for a complete 400 ms measurement. Do not chase silence or
            // a noise floor below -60 LUFS. This is a live leveler, not an
            // integrated-programme loudness meter or true-peak processor.
            double hopLUFS = -.691 + 10*log10(fmax(energy, 1e-20));
            if (s->windowCount == 40 && hopLUFS > -60) {
                double loudness = -.691 + 10*log10(fmax(s->energySum / 40, 1e-20));
                double correctionDB = fmin(12.0, fmax(-18.0, -18.0 - loudness));
                s->targetGain = pow(10, correctionDB / 20);
            } else {
                s->targetGain = 1;
            }
            s->hopEnergy = 0;
            s->hopCount = 0;
        }
    }
    double step = !enabled ? s->bypassStep : s->targetGain < s->gain ? s->attackStep : s->releaseStep;
    s->gain += (s->targetGain - s->gain) * step;
    if (fabs(s->targetGain - s->gain) < 1e-6) s->gain = s->targetGain;
    return s->gain;
}
