#if os(iOS)
import ActivityKit
import Foundation

/// Shared app/extension schema for TV remote quick access.
/// Compiled into both the Runner app (which starts/updates the Live Activity)
/// and the RemoteActivity widget extension (which renders it), so keep them in sync.
@available(iOS 16.2, *)
struct RemoteActivityAttributes: ActivityAttributes {
    /// Live state pushed from `remoteSnapshot` while the phone controls the TV.
    struct ContentState: Codable, Hashable {
        /// Show title playing on the TV.
        var title: String
        /// Episode label, or a generic "TV remote" caption.
        var episode: String
        /// Whether the TV player is currently playing (drives the play/pause glyph).
        var playing: Bool
    }
    /// Fixed activity label set when the activity is requested.
    var name: String
}
#endif
