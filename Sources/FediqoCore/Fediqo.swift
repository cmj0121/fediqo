/// The name this package answers to.
public enum Fediqo {
    public static let name = "Fediqo"

    /// What this app calls itself on the wire.
    ///
    /// **A name and a way to reach whoever wrote it, and no version.** The name alone was what
    /// went out before, and a bare token with no contact is what some filters in front of forums
    /// are configured to turn away — an administrator who sees this in a log can find out what it
    /// is and decide, which a one-word agent does not let them do. No version number, because
    /// this package has no honest way to read the one the app was built with, and a constant that
    /// drifts is worse than silence.
    ///
    /// It is **not** a browser's agent and must never be made into one. Claiming to be a browser
    /// is how a client gets past a filter that was put there on purpose, and a server that does
    /// not want to be read by an app is entitled to say so.
    public static let userAgent = "Fediqo (+https://github.com/cmj0121/fediqo)"

    public static func isNamed(_ value: String) -> Bool {
        value == name
    }
}
