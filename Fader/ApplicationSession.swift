/// Session-only visibility. An app earns a row by playing audio and keeps it
/// while at least one of its running instances survives each refresh.
struct ApplicationSession {
    private var instances: [String: Set<Int32>] = [:]

    mutating func update(playing: Set<String>, running: [String: Set<Int32>]) -> Set<String> {
        var retained: [String: Set<Int32>] = [:]
        for (id, previous) in instances {
            if let current = running[id], !current.isDisjoint(with: previous) {
                retained[id] = current
            }
        }
        for id in playing {
            if let current = running[id], !current.isEmpty { retained[id] = current }
        }
        instances = retained
        return Set(retained.keys)
    }
}
