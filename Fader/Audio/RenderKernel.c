#include "RenderKernel.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Only the render thread accesses currentGain. Control-thread changes are atomic.
// No allocations, locks, Swift ARC, logging, or dispatch in the audio callback.
struct FaderRenderState {
    _Atomic(float) targetGain;
    float currentGain;
    unsigned inputChannelOffset;
    double gainCeiling;
    double releaseStep;
    unsigned holdFrames;
    unsigned holdRemaining;
};

static float clampedGain(float gain) {
    return isfinite(gain) ? fminf(FaderMaximumGain, fmaxf(0, gain)) : 0;
}

FaderRenderState *FaderRenderCreate(float gain, unsigned offset, double sampleRate) {
    if (!isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 768000) return NULL;
    FaderRenderState *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    gain = clampedGain(gain);
    atomic_init(&s->targetGain, gain);
    _Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2,
                   "Fader needs lock-free atomics on the target architecture");
    s->currentGain = gain;
    s->inputChannelOffset = offset;
    s->gainCeiling = FaderMaximumGain;
    s->holdFrames = (unsigned)ceil(sampleRate * 0.05);
    s->releaseStep = -expm1(-1 / (sampleRate * 0.12));
    return s;
}
void FaderRenderDestroy(FaderRenderState *s) { free(s); }
void FaderRenderSetGain(FaderRenderState *s, float gain) {
    atomic_store_explicit(&s->targetGain, clampedGain(gain), memory_order_relaxed);
}

static const AudioBuffer *channelBuffer(const AudioBufferList *list, unsigned channel, unsigned *local) {
    for (unsigned i = 0; i < list->mNumberBuffers; ++i) {
        if (channel < list->mBuffers[i].mNumberChannels) {
            *local = channel;
            return &list->mBuffers[i];
        }
        channel -= list->mBuffers[i].mNumberChannels;
    }
    return NULL;
}
static float sample(const AudioBuffer *b, unsigned channel, unsigned frame) {
    if (!b || !b->mData || !b->mNumberChannels) return 0;
    size_t index = (size_t)frame * b->mNumberChannels + channel;
    float value = index < b->mDataByteSize / sizeof(float) ? ((const float *)b->mData)[index] : 0;
    return isfinite(value) ? value : 0;
}
void FaderRender(const AudioBufferList *input, AudioBufferList *output, FaderRenderState *s) {
    if (!output) return;
    unsigned frames = 0, channels = 0;
    for (unsigned b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer *out = &output->mBuffers[b];
        if (out->mData) memset(out->mData, 0, out->mDataByteSize);
        if (out->mNumberChannels && out->mData) {
            unsigned n = out->mDataByteSize / (sizeof(float) * out->mNumberChannels);
            if (n > frames) frames = n;
        }
        channels += out->mNumberChannels;
    }
    if (!input || !s) return;
    unsigned l = 0, r = 0;
    const AudioBuffer *left = channelBuffer(input, s->inputChannelOffset, &l);
    const AudioBuffer *right = channelBuffer(input, s->inputChannelOffset + 1, &r);
    float target = atomic_load_explicit(&s->targetGain, memory_order_relaxed);
    float gain = s->currentGain;
    // Ramp over at most 128 frames to avoid clicks while moving a slider.
    unsigned ramp = frames < 128 ? frames : 128;
    float step = ramp ? (target - gain) / ramp : 0;
    for (unsigned f = 0; f < frames; ++f) {
        if (f < ramp) gain += step;
        // Track a stereo-linked gain ceiling instead of reshaping each peak.
        // Hold for 50 ms so the limiter does not recover between waveform cycles,
        // then release with a 120 ms time constant. Attack is immediate: this
        // needs no lookahead, extra buffers, or added latency.
        double dryA = sample(left, l, f), dryB = sample(right, r, f);
        double peak = fmax(fabs(dryA), fabs(dryB));
        double ceiling = peak > 1.0 / FaderMaximumGain ? 1 / peak : FaderMaximumGain;
        if (ceiling <= s->gainCeiling) {
            s->gainCeiling = ceiling;
            s->holdRemaining = s->holdFrames;
        } else if (s->holdRemaining) {
            s->holdRemaining--;
        } else {
            s->gainCeiling += (ceiling - s->gainCeiling) * s->releaseStep;
        }
        // Valid full-scale input always has a ceiling >= 1, so 100% and
        // attenuation remain transparent. Double products also bound oversized
        // finite input before it can overflow a Float32 output.
        double appliedGain = fmin((double)gain, s->gainCeiling);
        double a = dryA * appliedGain, b = dryB * appliedGain;
        unsigned global = 0;
        for (unsigned i = 0; i < output->mNumberBuffers; ++i) {
            AudioBuffer *out = &output->mBuffers[i];
            for (unsigned c = 0; c < out->mNumberChannels; ++c, ++global) {
                size_t index = (size_t)f * out->mNumberChannels + c;
                if (!out->mData || index >= out->mDataByteSize / sizeof(float)) continue;
                double value = channels == 1 ? (a + b) * 0.5 : (global == 0 ? a : global == 1 ? b : 0);
                ((float *)out->mData)[index] = (float)value;
            }
        }
    }
    s->currentGain = target;
}
OSStatus FaderIOProc(AudioObjectID device, const AudioTimeStamp *now,
                    const AudioBufferList *input, const AudioTimeStamp *inputTime,
                    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    FaderRender(input, output, context);
    return noErr;
}
OSStatus FaderCreateIOProc(AudioObjectID device, FaderRenderState *state, AudioDeviceIOProcID *ioProc) {
    return AudioDeviceCreateIOProcID(device, FaderIOProc, state, ioProc);
}
