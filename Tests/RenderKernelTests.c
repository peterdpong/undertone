#include "RenderKernel.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { UInt32 count; AudioBuffer buffers[3]; } Buffers;
static void near(float actual, float expected) { assert(fabsf(actual - expected) < 0.00001f); }

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
    puts("PASS: gain, stereo layouts, microphone exclusion, mono, mute, smoothing, truncation, null buffers, nonfinite gain");
    return 0;
}
