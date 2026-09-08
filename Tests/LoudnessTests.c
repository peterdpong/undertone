#include "RenderKernel.h"
#include "LoudnessLeveler.h"
#include <assert.h>
#include <math.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void near(double a, double b, double tolerance) { assert(fabs(a-b) < tolerance); }

// Stream a synthetic tone, measuring only the last second. No audio hardware.
static double tone(FaderRenderState *s, double rate, double seconds, float amplitude, bool inverse) {
    float input[2048], output[2048];
    unsigned total = (unsigned)llround(rate*seconds), cursor = 0, measured = 0;
    double energy = 0;
    while (cursor < total) {
        unsigned frames = total-cursor < 1024 ? total-cursor : 1024;
        for (unsigned i = 0; i < frames; i++) {
            input[2*i] = amplitude * (float)sin(2*M_PI*1000*(cursor+i)/rate);
            input[2*i+1] = (inverse ? -1 : 1) * input[2*i];
        }
        AudioBufferList in = {1, {{2, frames*2*sizeof(float), input}}};
        AudioBufferList out = {1, {{2, frames*2*sizeof(float), output}}};
        FaderRender(&in, &out, s);
        for (unsigned i = 0; i < frames; i++) {
            assert(isfinite(output[2*i]) && fabsf(output[2*i]) <= 1);
            near(output[2*i+1], (inverse ? -1 : 1)*output[2*i], 1e-6);
            if (cursor+i >= total-fmin(total, rate)) {
                energy += (double)output[2*i]*output[2*i]; measured++;
            }
        }
        cursor += frames;
    }
    return sqrt(energy/measured);
}

static void testLeveling(void) {
    const double rates[] = {44100, 48000, 96000, 192000};
    double reference = 0;
    for (unsigned r = 0; r < 4; r++) {
        FaderRenderState *quiet = FaderRenderCreate(1, 0, rates[r]);
        FaderRenderState *loud = FaderRenderCreate(1, 0, rates[r]);
        FaderRenderState *inverted = FaderRenderCreate(1, 0, rates[r]);
        FaderRenderSetLoudnessEqualization(quiet, true);
        FaderRenderSetLoudnessEqualization(loud, true);
        FaderRenderSetLoudnessEqualization(inverted, true);
        double a = tone(quiet, rates[r], 10, .07, false);
        double b = tone(loud, rates[r], 10, .65, false);
        double c = tone(inverted, rates[r], 10, .07, true);
        assert(a > .07/sqrt(2)*1.2 && b < .65/sqrt(2)*.5);
        assert(fabs(20*log10(a/b)) < .1); // Quiet and loud settle within 0.1 dB.
        near(a, c, 1e-6); // Opposite-phase stereo cannot confuse the detector.
        if (r == 0) reference = a;
        assert(fabs(20*log10(a/reference)) < .1);
        FaderRenderSetLoudnessEqualization(quiet, false);
        tone(quiet, rates[r], .5, .07, false);
        near(tone(quiet, rates[r], 1, .07, false), .07/sqrt(2), 1e-6);
        FaderRenderSetLoudnessEqualization(quiet, true);
        near(tone(quiet, rates[r], .1, .65, false), .65/sqrt(2), 1e-6);
        FaderRenderDestroy(quiet); FaderRenderDestroy(loud); FaderRenderDestroy(inverted);
    }
}

static void testBypassAndGate(void) {
    FaderRenderState *s = FaderRenderCreate(1, 0, 48000);
    near(tone(s, 48000, 1, .07, false), .07/sqrt(2), 1e-6);
    FaderRenderSetLoudnessEqualization(s, true);
    near(tone(s, 48000, 2, .00001, false), .00001/sqrt(2), 1e-9);
    near(tone(s, 48000, 1, 0, false), 0, 1e-20);
    // Automatic gain is capped at +12 dB, even for very quiet eligible content.
    double limitedBoost = tone(s, 48000, 10, .002, false);
    assert(limitedBoost / (.002/sqrt(2)) <= pow(10, 12.0/20)+.0001);
    assert(limitedBoost > .002/sqrt(2)*3.5);
    FaderRenderSetGain(s, 0);
    tone(s, 48000, 1, .65, false);
    near(tone(s, 48000, 1, .65, false), 0, 1e-20);
    FaderRenderDestroy(s);
}

static void testTransientBoundsAndBlocks(void) {
    enum { frames = 48000*2 };
    float *input = malloc(frames*2*sizeof(float));
    float *whole = malloc(frames*2*sizeof(float));
    float *chunks = malloc(frames*2*sizeof(float));
    assert(input && whole && chunks);
    for (unsigned i = 0; i < frames; i++) {
        double level = (i/12000)%2 ? .9 : .03;
        input[2*i] = level*sin(2*M_PI*500*i/48000);
        input[2*i+1] = .5*level*sin(2*M_PI*1300*i/48000);
    }
    FaderRenderState *a = FaderRenderCreate(4, 0, 48000);
    FaderRenderState *b = FaderRenderCreate(4, 0, 48000);
    FaderRenderSetLoudnessEqualization(a, true);
    FaderRenderSetLoudnessEqualization(b, true);
    AudioBufferList in = {1, {{2, frames*2*sizeof(float), input}}};
    AudioBufferList out = {1, {{2, frames*2*sizeof(float), whole}}};
    FaderRender(&in, &out, a);
    const unsigned sizes[] = {1, 127, 256, 511, 64, 1024};
    for (unsigned cursor = 0, chunk = 0; cursor < frames;) {
        unsigned n = sizes[chunk++%6];
        if (n > frames-cursor) n = frames-cursor;
        in.mBuffers[0] = (AudioBuffer){2, n*2*sizeof(float), input+2*cursor};
        out.mBuffers[0] = (AudioBuffer){2, n*2*sizeof(float), chunks+2*cursor};
        FaderRender(&in, &out, b);
        cursor += n;
    }
    assert(memcmp(whole, chunks, frames*2*sizeof(float)) == 0);
    for (unsigned i = 0; i < frames; i++) {
        assert(isfinite(whole[2*i]) && fabsf(whole[2*i]) <= 1);
        assert(isfinite(whole[2*i+1]) && fabsf(whole[2*i+1]) <= 1);
        // Different-frequency channels receive one scalar gain, never tone EQ.
        near((double)whole[2*i]*input[2*i+1], (double)whole[2*i+1]*input[2*i], 1e-6);
    }
    float hostile[] = {NAN, INFINITY, FLT_MAX, -FLT_MAX}, safe[4];
    in.mBuffers[0] = (AudioBuffer){2, sizeof(hostile), hostile};
    out.mBuffers[0] = (AudioBuffer){2, sizeof(safe), safe};
    FaderRender(&in, &out, a);
    for (unsigned i = 0; i < 4; i++) assert(isfinite(safe[i]) && fabsf(safe[i]) <= 1);
    // Corrupt input must not leave the analysis stuck at minimum gain.
    FaderRenderSetGain(a, 1);
    double recovered = tone(a, 48000, 10, .07, false);
    FaderRenderState *fresh = FaderRenderCreate(1, 0, 48000);
    FaderRenderSetLoudnessEqualization(fresh, true);
    near(recovered, tone(fresh, 48000, 10, .07, false), 1e-5);
    FaderRenderDestroy(a); FaderRenderDestroy(b); FaderRenderDestroy(fresh);
    free(input); free(whole); free(chunks);
}

int main(void) {
    FaderLoudnessState reference;
    FaderLoudnessInit(&reference, 48000);
    near(reference.shelf.b0, 1.53512485958697, 1e-12);
    near(reference.shelf.a1, -1.69065929318241, 1e-12);
    near(reference.highpass.b0, 1, 1e-12);
    near(reference.highpass.a1, -1.99004745483398, 1e-12);
    testLeveling(); testBypassAndGate(); testTransientBoundsAndBlocks();
    puts("PASS: loudness leveling, 44.1–192 kHz, stereo/phase, bypass/re-enable, silence/noise gate, gain cap, mute, transient bounds, no tone EQ, callback partitioning, corrupt-input recovery");
}
