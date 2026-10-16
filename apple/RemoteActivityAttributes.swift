#if os(iOS)
import ActivityKit
import Foundation

/// Shared app/extension schema for TV remote quick access.
@available(iOS 16.2, *)
struct RemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var episode: String
        var playing: Bool
    }
    var name: String
}
#endif
