import ActivityKit
import WidgetKit
import SwiftUI

/// Quick access only. No silent audio or invented background playback is used
/// to keep the process running. Stale snapshots are labelled explicitly.
@main
struct BetaRemoteActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BetaRemoteActivityAttributes.self) { context in
            HStack {
                Image(systemName: "tv")
                VStack(alignment: .leading) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Text(context.isStale ? "Open Zangetsu to reconnect" : context.state.episode).font(.caption).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "tv") }
                DynamicIslandExpandedRegion(.center) {
                    VStack {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.episode).font(.caption).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Open Zangetsu to reconnect" : "Open Zangetsu • TV remote")
                        .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "tv")
            } compactTrailing: {
                Image(systemName: context.isStale ? "arrow.up.right" : context.state.playing ? "play.fill" : "pause.fill")
            } minimal: {
                Image(systemName: "tv")
            }
            .keylineTint(.pink)
        }
    }
}
