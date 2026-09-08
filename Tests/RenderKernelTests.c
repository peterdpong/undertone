#include "RenderKernel.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <float.h>

typedef struct { UInt32 count; AudioBuffer buffers[3]; } Buffers;
static void near(float actual, float expected) { assert(fabsf(actual - expected) < 0.00001f); }

static void testBoost(void) {
    float quiet[] = {.125, -.0625, .125, -.0625};
    float out[4];
    Buffers in = {1, {{2, sizeof(quiet), quiet}}};
    Buffers output = {1, {{2, sizeof(out), out}}};
    FaderRenderState *s = FaderRenderCreate(4, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], .5); near(out[1], -.25); near(out[2], .5); near(out[3], -.25);
    FaderRenderDestroy(s);

    // Changing gain above unity must work after creation, with a smooth ramp.
    s = FaderRenderCreate(1, 0);
    FaderRenderSetGain(s, 2);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], .1875); near(out[1], -.09375); near(out[2], .25); near(out[3], -.125);
    FaderRenderSetGain(s, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[2], 0); near(out[3], 0);
    FaderRenderSetGain(s, 4);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[2], .5); near(out[3], -.25);
    FaderRenderDestroy(s);

    // Hot signals stay in range and the linked limiter preserves stereo balance.
    float loud[] = {.8, -.4, -.8, .4};
    in.buffers[0].mData = loud;
    s = FaderRenderCreate(4, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], .995833333); near(out[0], -2 * out[1]);
    near(out[2], -out[0]); near(out[3], -out[1]);
    for (int i = 0; i < 4; i++) assert(fabsf(out[i]) <= 1);
    FaderRenderDestroy(s);

    // Unity keeps the original waveform, including peaks above the soft knee.
    float original[] = {.99, -.99, 1, -1};
    in.buffers[0].mData = original;
    s = FaderRenderCreate(1, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 0; i < 4; i++) near(out[i], original[i]);
    FaderRenderDestroy(s);

    // Entering boost must never reduce a valid signal's peaks below unity.
    float high[] = {.99, -.495, .95, -.475};
    in.buffers[0].mData = high;
    float previous = high[0];
    for (int percent = 100; percent <= 400; percent++) {
        s = FaderRenderCreate(percent / 100.0f, 0);
        FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
        assert(out[0] >= previous - 0.00001f && out[0] <= 1);
        near(out[0], -2 * out[1]);
        assert(out[2] >= high[2] - 0.00001f);
        previous = out[0];
        FaderRenderDestroy(s);
    }

    // Constructor and updates enforce the same gain ceiling; invalid gain mutes.
    in.buffers[0].mData = quiet;
    s = FaderRenderCreate(99, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], .5);
    FaderRenderSetGain(s, 99);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[2], .5);
    FaderRenderDestroy(s);
    s = FaderRenderCreate(NAN, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 0; i < 4; i++) near(out[i], 0);
    FaderRenderDestroy(s);

    // Hostile samples cannot contaminate the output with NaN or infinity.
    float invalid[] = {NAN, INFINITY, FLT_MAX, -FLT_MAX};
    in.buffers[0].mData = invalid;
    s = FaderRenderCreate(4, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], 0); near(out[1], 0);
    for (int i = 0; i < 4; i++) assert(isfinite(out[i]) && fabsf(out[i]) <= 1);
    FaderRenderDestroy(s);
}

static void testSteadyBoostAcrossBuffers(void) {
    // A steady periodic input must stay periodic at fixed gain, independently
    // of callback buffer boundaries. This catches kernel-induced warble/gaps;
    // it does not exercise Core Audio clocks or a screen-share capture graph.
    enum { frames = 48000, period = 240, channels = 2 };
    float *input = malloc(frames * channels * sizeof(float));
    float *whole = malloc(frames * channels * sizeof(float));
    float *chunked = malloc(frames * channels * sizeof(float));
    assert(input && whole && chunked);
    const unsigned chunkSizes[] = {1, 127, 256, 511, 64, 1024};
    const float amplitudes[] = {.05f, .8f}; // Linear boost and active peak protection.
    const float gains[] = {1, 2, 4};
    for (unsigned a = 0; a < sizeof(amplitudes) / sizeof(amplitudes[0]); a++) {
        for (unsigned f = 0; f < frames; f++) {
            double phase = 2 * M_PI * (f % period) / period;
            input[2 * f] = amplitudes[a] * (float)sin(phase);
            input[2 * f + 1] = amplitudes[a] * .5f * (float)sin(phase + .3);
        }
        for (unsigned g = 0; g < sizeof(gains) / sizeof(gains[0]); g++) {
            Buffers in = {1, {{channels, frames * channels * sizeof(float), input}}};
            Buffers out = {1, {{channels, frames * channels * sizeof(float), whole}}};
            FaderRenderState *s = FaderRenderCreate(gains[g], 0);
            FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, s);
            FaderRenderDestroy(s);
            s = FaderRenderCreate(gains[g], 0);
            unsigned f = 0, chunk = 0;
            while (f < frames) {
                unsigned n = chunkSizes[chunk++ % (sizeof(chunkSizes) / sizeof(chunkSizes[0]))];
                if (n > frames - f) n = frames - f;
                in.buffers[0] = (AudioBuffer){channels, n * channels * sizeof(float), input + f * channels};
                out.buffers[0] = (AudioBuffer){channels, n * channels * sizeof(float), chunked + f * channels};
                FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, s);
                f += n;
            }
            FaderRenderDestroy(s);
            for (unsigned i = 0; i < frames * channels; i++) {
                near(chunked[i], whole[i]);
                assert(isfinite(chunked[i]) && fabsf(chunked[i]) <= 1);
                if (i >= period * channels) near(chunked[i], chunked[i - period * channels]);
            }
        }
    }
    free(input); free(whole); free(chunked);
}

int main(void) {
    float stereo[] = { 0.8, -0.4, 0.2, -0.6 };
    float out[4] = { 9, 9, 9, 9 };
    Buffers in = {1, {{2, sizeof(stereo), stereo}}};
    Buffers output = {1, {{2, sizeof(out), out}}};
    FaderRenderState *s = FaderRenderCreate(0.5, 0);
    assert(s);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], 0.4); near(out[1], -0.2); near(out[2], 0.1); near(out[3], -0.3);
    FaderRenderDestroy(s);

    // Noninterleaved input and output, with a physical microphone preceding the tap.
    float microphone[] = {100, 100};
    float left[] = {0.8, 0.2}, right[] = {-0.4, -0.6}, lout[2], rout[2];
    in = (Buffers){3, {{1, sizeof(microphone), microphone}, {1, sizeof(left), left}, {1, sizeof(right), right}}};
    output = (Buffers){2, {{1, sizeof(lout), lout}, {1, sizeof(rout), rout}}};
    s = FaderRenderCreate(1, 1);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(lout[0], .8); near(rout[0], -.4); near(lout[1], .2); near(rout[1], -.6);
    FaderRenderDestroy(s);

    // Mono output downmix, then gain change reaches mute without a discontinuity.
    float mono[2];
    output = (Buffers){1, {{1, sizeof(mono), mono}}};
    s = FaderRenderCreate(1, 1);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(mono[0], .2); near(mono[1], -.2);
    FaderRenderSetGain(s, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(mono[0], .1); near(mono[1], 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(mono[0], 0); near(mono[1], 0);
    FaderRenderDestroy(s);

    // Truncated input, extra output channels, null buffers: silence, never out-of-bounds.
    float surround[12];
    in = (Buffers){1, {{2, sizeof(float) * 2, stereo}}};
    output = (Buffers){1, {{6, sizeof(surround), surround}}};
    s = FaderRenderCreate(1, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(surround[0], .8); near(surround[1], -.4);
    for (int i = 2; i < 12; i++) near(surround[i], 0);
    in.buffers[0].mData = NULL;
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 0; i < 12; i++) near(surround[i], 0);
    FaderRender(NULL, (AudioBufferList *)&output, s);
    FaderRender((AudioBufferList *)&in, NULL, s);
    FaderRenderSetGain(s, NAN);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 0; i < 12; i++) assert(isfinite(surround[i]));
    FaderRenderDestroy(s);

    // Full 128-frame smoothing ramp is monotonic and ends at the requested gain.
    float ones[256], ramp[256];
    for (int i = 0; i < 256; i++) ones[i] = 1;
    in = (Buffers){1, {{2, sizeof(ones), ones}}};
    output = (Buffers){1, {{2, sizeof(ramp), ramp}}};
    s = FaderRenderCreate(1, 0);
    FaderRenderSetGain(s, .25);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 2; i < 256; i++) assert(ramp[i] <= ramp[i - 2]);
    near(ramp[254], .25); near(ramp[255], .25);
    FaderRenderDestroy(s);
    testBoost();
    testSteadyBoostAcrossBuffers();
    puts("PASS: gain, layouts, microphone exclusion, mono, mute, ramps, buffer bounds, boost, peak limiting, nonfinite values, steady-tone/buffer continuity");
    return 0;
}
