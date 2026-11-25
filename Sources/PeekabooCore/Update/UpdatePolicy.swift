import Foundation

/// What started an update check.
public enum UpdateTrigger: String, Sendable {
    /// `firstCheckDelay` after launch.
    case launch
    /// Every `interval` while the app runs.
    case timer
    /// The network came back (offline → online).
    case connectivity
    /// "Check for Updates…" or the Settings window: never throttled, runs with `[updates] check = false` too.
    case manual
}

/// When the updater talks to the network: never on the launch path, at most once per `minimumSpacing`
/// unless asked.
public struct UpdatePolicy: Sendable, Equatable {
    /// The first automatic check runs this long after launch (the first frame is long on screen by then).
    public var firstCheckDelay: TimeInterval = 10
    /// Automatic re-check while the app stays open.
    public var interval: TimeInterval = 6 * 3600
    /// Automatic checks closer than this to the last one are skipped (relaunches, flapping Wi-Fi).
    public var minimumSpacing: TimeInterval = 3600

    public init() {}

    /// Whether a check started by `trigger` runs now. `lastCheck` is the last completed check.
    public func shouldCheck(_ trigger: UpdateTrigger, automatic enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        if trigger == .manual { return true }
        guard enabled else { return false }
        guard let lastCheck else { return true }
        // A clock set backwards makes the last check look like the future: check rather than wait for it.
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= minimumSpacing || elapsed < 0
    }
}

/// Turns network path reports into "the connection is back" events. The first report (sent as soon as a
/// monitor starts) only sets the baseline.
public struct ConnectivityEdge: Sendable {
    private var online: Bool?

    public init() {}

    /// Record a report; true when it is the transition from offline to online.
    public mutating func update(online now: Bool) -> Bool {
        defer { online = now }
        return online == false && now
    }
}
