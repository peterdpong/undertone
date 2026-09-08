# Fader

A small, native macOS menu bar volume mixer, built in the style of [Horizon](https://github.com/peterdpong/horizon). SwiftUI interface, Core Audio process taps, and a small C audio callback. No third-party packages, audio drivers, daemons, accounts, analytics, or network requests.

## Controls

- Per-app volume (0–400%) and mute; unmuting restores the saved level, including boost.
- Per-app output routing, with a system-output default.
- System output selection and hardware volume where supported.
- Microphone/input selection and hardware input gain where supported.
- Saved app levels and routes, automatic mixing while Fader runs, and optional launch at login.
- Only applications with active audio output appear. Paused apps disappear while keeping their saved volume, boost, mute, and routing settings. Each app shows its effective output's icon; click it to select an output directly. The reset arrow restores 100% volume and unmutes without changing the selected output.
- Unplugged app outputs fall back to the system output and reconnect when available.
- Named mix presets, saved from the current state and managed in a native Settings window.

Input selection changes the macOS default input. Apps with their own microphone selection may override it. Per-app controls apply to playback; they do not mix microphones. Browser helper processes are grouped under their containing app when the system exposes that identity; separate browser tabs are not separate sliders.

The application filter follows Core Audio's output-running notifications, with no polling or extra audio taps. An app that keeps its output stream running through silence may remain visible. Muting an app in Fader does not itself hide its active stream, so the unmute control stays available.

FaceTime and Apple's `avconferenced` / `callservicesd` helpers are excluded from app mixing. Intercepting their playback can disrupt call echo cancellation and cause quiet call audio or an echo for the other person. Use macOS controls for FaceTime and adjust the browser or media app separately. Existing call-volume preferences and preset entries are removed automatically; the remaining preset settings are preserved. App sliders use 1% steps, and levels that round to 100% bypass processing on the default output.

**FaceTime screen sharing is not yet compatible with boosted shared-app audio.** A user reported a vibrato/warbling effect for the viewer when boosting the shared app. Excluding FaceTime does not remove the shared app's processing path. As a workaround, reset the shared app to 100%, unmuted, and choose System Output to release its tap; quitting Fader releases every tap. Confirm the result with the viewer. The capture/timing cause and a fix that preserves boost during sharing remain unverified. Similar reports exist in [FineTune #200](https://github.com/ronitsingh10/FineTune/issues/200) and [#292](https://github.com/ronitsingh10/FineTune/issues/292).

## Build and run

Requires macOS 14.2+, Xcode 26+ (Swift 6.2+), and XcodeGen. There are no packages to download during a build.

```sh
make build       # Debug build, local ad-hoc signature
make run         # Build and open the menu bar app
make release     # Optimized local build
make test        # C audio tests with AddressSanitizer and UndefinedBehaviorSanitizer
make diagnose    # Read-only list of audio devices and processes
```

The optimized application is at `build/Build/Products/Release/Fader.app` (approximately 2.2 MB, universal Apple Silicon/Intel). Open it directly or copy it to Applications. The generated Xcode project is checked in; `project.yml` is the source of truth. The default build uses an ad-hoc signature for local development. Public distribution requires your Developer ID signature and notarization; this repository does not publish or install anything automatically.

Debug builds also support `open build/Build/Products/Debug/Fader.app --args --show-panel` after quitting any running copy. This opens the same panel in a conventional window for accessibility/layout verification. Release builds have the menu bar panel and Settings window.

## First use and audio permission

1. Open Fader using the three-slider menu bar icon.
2. Play audio in an app and adjust that app's volume or output. Mixing is active whenever Fader is running.
3. Allow the macOS system audio request. Fader processes samples in memory and never records or uploads them.
4. If access is denied, use **Audio access settings** in the gear menu, enable Fader in **Privacy & Security → Screen & System Audio Recording**, then quit and reopen Fader. The exact pane title varies by macOS version.

Reset clears app levels and routes. Quitting destroys the private taps/devices and restores direct app playback; reopening Fader automatically restores saved app settings. Device selections and device volumes are ordinary macOS settings and remain where you set them.

## Lightweight by design

Discovery uses Core Audio property listeners with a short event-coalescing delay, not a polling timer. Apps at 100% on their normal output bypass the audio engine entirely. Only playing apps that need gain, mute, or routing get a private tap and aggregate device. Sleeping and stopping playback release those resources. The render callback uses lock-free gain updates, performs no heap allocation or Swift ARC, and ramps changes over up to 128 frames.

## Mix presets

Set up your mix, open **Presets → Save Current Mix…**, and name it—for example, “FaceTime” with your browser at 200%. Choose its name from the same menu to apply it. Switching is manual; Fader does not watch calls or automatically change presets.

Presets save playing apps plus previously adjusted apps, including boost, mute, and per-app output routes. They also save the system input/output selections and their supported hardware levels. Saved app identities survive app restarts, so an inactive browser receives its saved boost when it next plays. Transient sources identified only by process ID are omitted because those IDs can belong to another process after relaunch.

**Manage Presets…** opens a sidebar settings window modeled on Horizon. Select a preset to inspect its saved mix, rename it, or choose **Use Current Mix → Save** to replace its snapshot. The plus button saves another snapshot; minus deletes the selected preset without changing the live mix. **Apply** restores a saved preset. Unsaved edits must be saved or reverted before applying.

Applying a preset replaces app preferences, resetting apps absent from that preset to 100%, unmuted, on the system output. A disconnected system device leaves the current device in place and shows a message; disconnected per-app routes use the existing system-output fallback. The menu checks a preset only while its settings match the current mix. Presets are stored locally as small JSON data in UserDefaults, with no background service or polling. Resetting live app levels does not delete presets.

## Boosting quiet apps

Drag an application's slider above 100%, or Control-click the percentage for 100%, 200%, and 400% presets. Click the reset arrow to return to 100% without changing its output route. Hardware output and microphone sliders remain at their supported 0–100% range.

200% applies 2× amplitude (about +6 dB); 400% applies 4× (about +12 dB), before peak protection. These percentages do not represent perceived loudness. Soft peak limiting keeps each boosted app's samples within full scale and preserves left/right balance. Quiet signals receive the requested gain; loud peaks receive less gain. The limiter uses no lookahead or added buffering. It can color loud audio and cannot repair distortion already present in the source or guarantee that the final sum of multiple apps will not clip.

For a video that gets quieter during a FaceTime call, boost the video/browser app. FaceTime and its call helpers stay on their normal audio path and cannot be adjusted in Fader. Browser boost adds gain to captured app audio; it does not disable macOS ducking. Its effectiveness during FaceTime, and changes in level when a call ends, still require a live-call test on the target device. Return the app to 100% when the extra gain is no longer needed.

The current engine mixes down to stereo, supports Float32 devices, and sends stereo to the first two output channels (or downmixes for a mono output). It is not a bit-perfect multichannel/pro-audio router. HDMI/DisplayPort hardware volume is often read-only, although individual app attenuation still works. DRM-protected or exclusive-device playback may not be capturable. Latency and CPU usage depend on the output device and number of adjusted apps.

## Validation status

See [docs/VALIDATION.md](docs/VALIDATION.md) for verified behavior and the remaining live audio/device test matrix. Building and passing the DSP tests does not establish end-to-end audio compatibility with every Mac, Bluetooth device, or application.

## Existing alternatives

This category already exists: [SoundSource](https://rogueamoeba.com/soundsource/) and [Sound Control](https://staticz.com/soundcontrol/) offer extensive mixing and routing. [Background Music](https://github.com/kyleneideck/BackgroundMusic) is an open-source alternative. Fader focuses on a minimal native panel and modern public Core Audio taps rather than effects, EQ, or a driver installer.

Apple's [Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) documents the underlying API and audio permission requirement.
