#include "RenderKernel.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <float.h>

typedef struct { UInt32 count; AudioBuffer buffers[3]; } Buffers;
static void near(float actual, float expected) {
    if (fabsf(actual - expected) >= 0.00001f) fprintf(stderr, "Expected %.8f, got %.8f\n", expected, actual);
    assert(fabsf(actual - expected) < 0.00001f);
}

static void settle(FaderRenderState *s) {
    float silence[2048] = {0}, output[2048];
    Buffers in = {1, {{2, sizeof(silence), silence}}};
    Buffers out = {1, {{2, sizeof(output), output}}};
    for (int i = 0; i < 48; i++) FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, s);
}

static void testBoost(void) {
    float quiet[] = {.125, -.0625, .125, -.0625};
    float out[4];
    Buffers in = {1, {{2, sizeof(quiet), quiet}}};
    Buffers output = {1, {{2, sizeof(out), out}}};
    FaderRenderState *s = FaderRenderCreate(4, 0, 48000);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], .5); near(out[1], -.25); near(out[2], .5); near(out[3], -.25);
    FaderRenderDestroy(s);

    // Changing gain above unity must work after creation, with a smooth ramp.
    s = FaderRenderCreate(1, 0, 48000);
    FaderRenderSetGain(s, 2);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    assert(out[0] > .125 && out[2] > out[0] && out[2] < .25);
    settle(s);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[2], .25); near(out[3], -.125);
    FaderRenderSetGain(s, 0);
    settle(s);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[2], 0); near(out[3], 0);
    FaderRenderSetGain(s, 4);
    settle(s);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[2], .5); near(out[3], -.25);
    FaderRenderDestroy(s);

    // Hot signals stay in range and the linked limiter preserves stereo balance.
    float loud[] = {.8, -.4, -.8, .4};
    in.buffers[0].mData = loud;
    s = FaderRenderCreate(4, 0, 48000);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], 1); near(out[0], -2 * out[1]);
    near(out[2], -out[0]); near(out[3], -out[1]);
    for (int i = 0; i < 4; i++) assert(fabsf(out[i]) <= 1);
    FaderRenderDestroy(s);

    // Unity keeps the original waveform, including full-scale peaks.
    float original[] = {.99, -.99, 1, -1};
    in.buffers[0].mData = original;
    s = FaderRenderCreate(1, 0, 48000);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 0; i < 4; i++) near(out[i], original[i]);
    FaderRenderDestroy(s);

    // Entering boost must never reduce a valid signal's peaks below unity.
    float high[] = {.99, -.495, .95, -.475};
    in.buffers[0].mData = high;
    float previous = high[0];
    for (int percent = 100; percent <= 400; percent++) {
        s = FaderRenderCreate(percent / 100.0f, 0, 48000);
        FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
        assert(out[0] >= previous - 0.00001f && out[0] <= 1);
        near(out[0], -2 * out[1]);
        assert(out[2] >= high[2] - 0.00001f);
        previous = out[0];
        FaderRenderDestroy(s);
    }

    // Constructor and updates enforce the same gain ceiling; invalid gain mutes.
    in.buffers[0].mData = quiet;
    s = FaderRenderCreate(99, 0, 48000);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], .5);
    FaderRenderSetGain(s, 99);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[2], .5);
    FaderRenderDestroy(s);
    s = FaderRenderCreate(NAN, 0, 48000);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 0; i < 4; i++) near(out[i], 0);
    FaderRenderDestroy(s);

    // Hostile samples cannot contaminate the output with NaN or infinity.
    float invalid[] = {NAN, INFINITY, FLT_MAX, -FLT_MAX};
    in.buffers[0].mData = invalid;
    s = FaderRenderCreate(4, 0, 48000);
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
            FaderRenderState *s = FaderRenderCreate(gains[g], 0, 48000);
            FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, s);
            FaderRenderDestroy(s);
            s = FaderRenderCreate(gains[g], 0, 48000);
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
                if (i >= 4800 * channels) near(chunked[i], chunked[i - period * channels]);
            }
        }
    }
    free(input); free(whole); free(chunked);
}


static void testBoostFidelity(void) {
    // Fit the settled output to the original sine. The residual catches both
    // harmonic distortion and gain modulation, including the old soft clipper.
    const double rates[] = {44100, 48000, 96000, 192000};
    const double frequencies[] = {40, 200, 1000, 6000};
    const float gains[] = {1.4f, 4};
    double worst = 0;
    for (unsigned r = 0; r < 4; r++) {
        unsigned frames = (unsigned)rates[r];
        float *input = calloc(frames * 2, sizeof(float));
        float *output = calloc(frames * 2, sizeof(float));
        assert(input && output);
        Buffers in = {1, {{2, frames * 2 * sizeof(float), input}}};
        Buffers out = {1, {{2, frames * 2 * sizeof(float), output}}};
        for (unsigned f = 0; f < 4; f++) {
            for (unsigned i = 0; i < frames; i++) {
                input[2*i] = .99f * (float)sin(2*M_PI*frequencies[f]*i/rates[r]);
                input[2*i+1] = -.5f * input[2*i];
            }
            for (unsigned g = 0; g < 2; g++) {
                FaderRenderState *state = FaderRenderCreate(gains[g], 0, rates[r]);
                assert(state);
                FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, state);
                FaderRenderDestroy(state);
                double dot = 0, norm = 0, energy = 0, residual = 0;
                for (unsigned i = 0; i < frames; i++) {
                    assert(isfinite(output[2*i]) && fabsf(output[2*i]) <= 1);
                    near(output[2*i+1], -.5f * output[2*i]);
                    if (i < frames / 2) continue; // Exclude limiter attack.
                    dot += (double)input[2*i] * output[2*i];
                    norm += (double)input[2*i] * input[2*i];
                    energy += (double)output[2*i] * output[2*i];
                }
                double fittedGain = dot / norm;
                assert(fittedGain > 1 && fittedGain <= gains[g]);
                for (unsigned i = frames / 2; i < frames; i++) {
                    double error = output[2*i] - fittedGain * input[2*i];
                    residual += error * error;
                }
                double distortion = sqrt(residual / energy);
                worst = fmax(worst, distortion);
                assert(distortion < .00001); // Less than 0.001% residual.
            }
        }
        free(input); free(output);
    }
    printf("PASS: 140%%/400%% steady boost, 40–6000 Hz, 44.1–192 kHz; worst residual %.6f%%\n", worst * 100);
}

static void testLimiterRecovery(void) {
    const double rates[] = {44100, 48000, 96000, 192000};
    for (unsigned r = 0; r < 4; r++) {
        unsigned hold = (unsigned)ceil(rates[r] * .05);
        unsigned release = (unsigned)ceil(rates[r] * .12);
        unsigned frames = 1 + hold + release;
        float *input = malloc(frames * 2 * sizeof(float));
        float *output = malloc(frames * 2 * sizeof(float));
        assert(input && output);
        for (unsigned i = 0; i < frames * 2; i++) input[i] = .1f;
        input[0] = 1; input[1] = -.5f; // Sudden peak, caught without an overshoot.
        Buffers in = {1, {{2, frames * 2 * sizeof(float), input}}};
        Buffers out = {1, {{2, frames * 2 * sizeof(float), output}}};
        FaderRenderState *state = FaderRenderCreate(4, 0, rates[r]);
        FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, state);
        near(output[0], 1); near(output[1], -.5);
        for (unsigned i = 1; i <= hold; i++) near(output[2*i], .1);
        for (unsigned i = hold + 1; i < frames; i++) {
            assert(output[2*i] >= output[2*(i-1)] && output[2*i] <= .4);
            assert(output[2*i] - output[2*(i-1)] < .0001);
        }
        near(output[2*(frames-1)], .1 * (4 - 3 * exp(-(double)release / (rates[r] * .12))));
        FaderRenderSetGain(state, 1);
        input[0] = input[1] = .1f;
        for (int i = 0; i < 4; i++) FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, state);
        near(output[2*(frames-1)], .1); // Reset clears boost without residual attenuation.
        FaderRenderDestroy(state);
        free(input); free(output);
    }
    assert(!FaderRenderCreate(4, 0, 0));
    assert(!FaderRenderCreate(4, 0, NAN));
    assert(!FaderRenderCreate(4, 0, INFINITY));
}

static void testVolumeSmoothing(void) {
    const double rates[] = {44100, 48000, 96000, 192000};
    for (unsigned r = 0; r < 4; r++) {
        unsigned frames = (unsigned)llround(rates[r] * .03);
        float *input = malloc(frames * 2 * sizeof(float));
        float *whole = malloc(frames * 2 * sizeof(float));
        float *chunked = malloc(frames * 2 * sizeof(float));
        assert(input && whole && chunked);
        for (unsigned i = 0; i < frames * 2; i++) input[i] = .1;
        Buffers in = {1, {{2, frames * 2 * sizeof(float), input}}};
        Buffers out = {1, {{2, frames * 2 * sizeof(float), whole}}};
        FaderRenderState *a = FaderRenderCreate(.2, 0, rates[r]);
        FaderRenderState *b = FaderRenderCreate(.2, 0, rates[r]);
        FaderRenderSetGain(a, .8); FaderRenderSetGain(b, .8);
        FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, a);
        for (unsigned offset = 0; offset < frames;) {
            unsigned n = frames - offset < 37 ? frames - offset : 37;
            in.buffers[0] = (AudioBuffer){2, n * 2 * sizeof(float), input + 2*offset};
            out.buffers[0] = (AudioBuffer){2, n * 2 * sizeof(float), chunked + 2*offset};
            FaderRender((AudioBufferList *)&in, (AudioBufferList *)&out, b);
            offset += n;
        }
        for (unsigned i = 0; i < frames * 2; i++) near(chunked[i], whole[i]);
        near(whole[2*(frames-1)], .1 * (.8 - .6 * exp(-(double)frames/(rates[r]*.03))));
        FaderRenderDestroy(a); FaderRenderDestroy(b);
        free(input); free(whole); free(chunked);
    }
}

int main(void) {
    float stereo[] = { 0.8, -0.4, 0.2, -0.6 };
    float out[4] = { 9, 9, 9, 9 };
    Buffers in = {1, {{2, sizeof(stereo), stereo}}};
    Buffers output = {1, {{2, sizeof(out), out}}};
    FaderRenderState *s = FaderRenderCreate(0.5, 0, 48000);
    assert(s);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(out[0], 0.4); near(out[1], -0.2); near(out[2], 0.1); near(out[3], -0.3);
    FaderRenderDestroy(s);

    // Noninterleaved input and output, with a physical microphone preceding the tap.
    float microphone[] = {100, 100};
    float left[] = {0.8, 0.2}, right[] = {-0.4, -0.6}, lout[2], rout[2];
    in = (Buffers){3, {{1, sizeof(microphone), microphone}, {1, sizeof(left), left}, {1, sizeof(right), right}}};
    output = (Buffers){2, {{1, sizeof(lout), lout}, {1, sizeof(rout), rout}}};
    s = FaderRenderCreate(1, 1, 48000);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(lout[0], .8); near(rout[0], -.4); near(lout[1], .2); near(rout[1], -.6);
    FaderRenderDestroy(s);

    // Mono output downmix, then gain change reaches mute without a discontinuity.
    float mono[2];
    output = (Buffers){1, {{1, sizeof(mono), mono}}};
    s = FaderRenderCreate(1, 1, 48000);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(mono[0], .2); near(mono[1], -.2);
    FaderRenderSetGain(s, 0);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    assert(mono[0] > 0 && mono[0] < .2 && mono[1] < 0);
    settle(s);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(mono[0], 0); near(mono[1], 0);
    FaderRenderDestroy(s);

    // Truncated input, extra output channels, null buffers: silence, never out-of-bounds.
    float surround[12];
    in = (Buffers){1, {{2, sizeof(float) * 2, stereo}}};
    output = (Buffers){1, {{6, sizeof(surround), surround}}};
    s = FaderRenderCreate(1, 0, 48000);
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

    // Volume smoothing is monotonic and eventually settles to the exact gain.
    float ones[256], ramp[256];
    for (int i = 0; i < 256; i++) ones[i] = 1;
    in = (Buffers){1, {{2, sizeof(ones), ones}}};
    output = (Buffers){1, {{2, sizeof(ramp), ramp}}};
    s = FaderRenderCreate(1, 0, 48000);
    FaderRenderSetGain(s, .25);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    for (int i = 2; i < 256; i++) assert(ramp[i] <= ramp[i - 2]);
    assert(ramp[254] > .25);
    settle(s);
    FaderRender((AudioBufferList *)&in, (AudioBufferList *)&output, s);
    near(ramp[254], .25); near(ramp[255], .25);
    FaderRenderDestroy(s);
    testBoost();
    testSteadyBoostAcrossBuffers();
    testBoostFidelity();
    testVolumeSmoothing();
    testLimiterRecovery();
    puts("PASS: gain, layouts, microphone exclusion, mono, mute, ramps, buffer bounds, boost, peak limiting, nonfinite values, steady-tone/buffer continuity");
    return 0;
}
