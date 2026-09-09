import Foundation

@main struct ApplicationSessionTests {
    static func main() {
        var session = ApplicationSession()
        let browser = "com.browser"
        let music = "com.music"
        let running: [String: Set<Int32>] = [browser: [100], music: [200]]
        precondition(session.update(playing: [], running: running).isEmpty, "Running apps must first play audio")
        precondition(session.update(playing: [browser], running: running) == [browser])
        precondition(session.update(playing: [], running: running) == [browser],
                     "Pausing or destroying the audio stream must keep a running app visible")
        precondition(session.update(playing: [music], running: running) == [browser, music])
        precondition(session.update(playing: [], running: [music: [200]]) == [music], "A fully closed app must disappear")
        precondition(session.update(playing: [], running: [browser: [101], music: [200]]) == [music],
                     "Relaunching quietly must not restore the old row")
        precondition(session.update(playing: [browser], running: [browser: [101], music: [200]]) == [browser, music])
        precondition(session.update(playing: [], running: [browser: [102], music: [200]]) == [music],
                     "A quit/relaunch between refreshes is a new app lifetime")

        var multiple = ApplicationSession()
        precondition(multiple.update(playing: [browser], running: [browser: [1, 2]]) == [browser])
        precondition(multiple.update(playing: [], running: [browser: [2, 3]]) == [browser],
                     "Keep the row while an app instance survives")
        precondition(multiple.update(playing: [], running: [browser: [3]]) == [browser])
        precondition(multiple.update(playing: [], running: [browser: []]).isEmpty)
        precondition(multiple.update(playing: [browser], running: [:]).isEmpty, "Stale playback cannot retain a closed app")

        var restartedMixer = ApplicationSession()
        precondition(restartedMixer.update(playing: [], running: running).isEmpty, "Visibility must be session-only")
        print("PASS: first playback, pause/stream removal, quit, quiet relaunch, rapid relaunch, multiple instances, session reset")
    }
}
