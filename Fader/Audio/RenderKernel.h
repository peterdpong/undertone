#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

static const float FaderMaximumGain = 4.0f;

typedef struct FaderRenderState FaderRenderState;
FaderRenderState *FaderRenderCreate(float gain, unsigned inputChannelOffset, double sampleRate);
void FaderRenderDestroy(FaderRenderState *state);
void FaderRenderSetGain(FaderRenderState *state, float gain);
void FaderRender(const AudioBufferList *input, AudioBufferList *output, FaderRenderState *state);
OSStatus FaderCreateIOProc(AudioObjectID device, FaderRenderState *state, AudioDeviceIOProcID *ioProc);
OSStatus FaderIOProc(AudioObjectID device, const AudioTimeStamp *now,
                    const AudioBufferList *input, const AudioTimeStamp *inputTime,
                    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
