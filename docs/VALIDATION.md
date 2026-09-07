# Validation

## Verified on the development Mac

- Xcode 26.6 Debug and optimized Release builds, Swift 6 strict concurrency, on macOS 27.0.
- Release is a universal Apple Silicon/Intel app, approximately 2.2 MB on disk. Local ad-hoc signature passes `codesign --verify --deep --strict`.
- Native app launch and live device/process discovery.
- Final Release discovery confirmed that Arc and Claude audio helpers are grouped under their parent applications.
- Discovered Mac mini Speakers, BenQ GW2480, and Q27G42ZE; monitor outputs correctly report hardware-controlled volume.
- Native panel inspected through accessibility and a screenshot.
- Initial panel: 50% slider state, mute/unmute, and restoration to 100% verified through the UI. The enable/bypass and inactive-app controls were subsequently removed in favor of automatic mixing and discovery.
- Revised panel: verified native system styling, automatic app list on launch with the old disabled preference still present, absence of the mixer toggle/status/footer, and the per-app output menu through accessibility and a screenshot. No audio settings were changed during this UI check.
- Audio kernel tests with AddressSanitizer and UndefinedBehaviorSanitizer: linear gain, interleaved and planar stereo, physical-input exclusion, mono downmix, mute, 128-frame ramp, short input, extra output channels, null buffers, and nonfinite gain.
- Boost regression coverage: quiet audio at 2×/4×, gain changes after creation, boost/mute ramps, linked peak limiting, original waveform preservation at 100%, monotonic loud peaks from 100–400%, consistent gain bounds, and nonfinite/oversized input samples.
- Settings regression coverage: boost activates processing, saved boost/mute round-trip, unmute restores boost, 100% releases processing unless routed, and old settings remain decodable.
- Boost UI verified at 200% and 400%, with mute and click-to-reset to 100%; inspected the 400% state visually. The test app was restored to its original 100% level afterward. Audible FaceTime behavior remains unverified.
- Active-audio filtering: verified that idle apps are hidden and the empty state is shown; inspected the native divider between output/input controls. App-row separators are inserted between rows, with no trailing separator. Filtering uses the existing Core Audio output-running listeners and leaves stored settings unchanged. An app that continuously runs a silent output stream can remain visible.
- Output/reset icons: used a silent `afplay` stream to show an active source, inspected its effective speaker icon, opened the direct device menu, selected the existing system output, and exercised the reset button at 100%. Screenshot also confirmed the divider between two active sources. Stopping the stream removed its row automatically. No new audio-capture permission or audible playback was involved; changing to another physical output remains in the live-audio matrix.
- Preset regression tests: independent snapshots, boost/mute/routing and device persistence, stable app identities, exclusion of recycled process IDs, matching after hardware rounding, manual-change detection, rename, deletion, and malformed stored data.
- Preset UI: saved a named current mix from the popover, verified the selected checkmark and restoration after relaunch, opened the native sidebar Settings view, renamed the test preset, replaced its snapshot with Use Current Mix, saved, and applied that unchanged mix. Verified Save/Revert/Apply enablement and General settings layout through accessibility and screenshots. Removed the temporary test preset afterward. No gain increase, call action, or physical device change was made in this preset UI check.

## Still requires live audio permission and hardware testing

System audio access has not been granted during development. No claim is made that audible attenuation or routing has been verified on this machine yet. Run this matrix before distributing:

1. Play a continuous test sound. Compare 100%, 50%, mute, unmute, quit, and relaunch. Verify both channels and absence of doubled playback. Saved settings must apply immediately after relaunch, even if an older version saved `mixingEnabled = false`.
2. Play two applications simultaneously. Adjust only one and verify the other is unchanged.
3. Test per-app routing to a second output. Confirm sound leaves the original destination and the system default remains unchanged.
4. Deny audio access, then grant it, quit, and relaunch. Verify recovery and inspect any Core Audio error in the app row. macOS can deliver silent tap buffers for unavailable/protected audio; quit Fader if playback is unexpectedly silent.
5. Switch the system output, disconnect/reconnect a routed device, and change the device sample rate. Verify fallback and recovery.
6. Test sleep/wake, app relaunch, helper-process replacement, Fader quit, and forced termination while playing. Confirm direct audio resumes.
7. Connect a microphone and a full-duplex USB/Bluetooth device. Verify input selection/gain and confirm microphone input never plays through the output.
8. Confirm headphones, USB devices, mono outputs, and supported macOS versions. Stereo is the current supported mixing format; channels beyond the first two output channels are silent.
9. Measure idle and 1/3/8 adjusted-app CPU, memory, and latency on target hardware. The app uses no periodic polling or audio-meter animation, but runtime performance has not been benchmarked under real mixing load.
10. While on a FaceTime call, play a quiet video in a separate app and compare 100%, 200%, and 400%. Verify that only the selected app is boosted. Test both while someone speaks and during pauses. End the call and check the resulting level before restoring 100%. Gain does not disable ducking and cannot guarantee compensation when attenuation occurs later in the system audio path.
11. Save a boosted browser mix as a preset, switch to a neutral preset, and switch back while audio plays. Quit/relaunch the browser and verify the saved boost resumes. Apply with a saved device disconnected and confirm the current system device stays selected while app routing falls back. Verify system input/output volume restoration on supported hardware.

## Implementation notes

- Process taps use `mutedWhenTapped`, not unconditional muting.
- IO is stopped and destroyed before render-state memory is freed. Failed setup rolls back all owned resources.
- Private aggregate devices are never made the global default output.
- All Swift control state is confined to the main actor; the real-time callback is C.
- Physical aggregate inputs are skipped by channel offset. Tap input is stereo and aggregate virtual formats are checked before starting IO.
- Per-app routes use stable device UIDs and preferences use app bundle IDs where available. Processes lacking bundle identity use their process ID for the current session.
- The C wrapper for IOProc registration avoids a Swift 6.3.3 compiler crash when Swift converts the imported callback directly.
