#if os(iOS)
import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct BetaRemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var episode: String
        var playing: Bool
    }
    var name: String
}
#endif
