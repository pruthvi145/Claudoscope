import Foundation
import SwiftUI
import os

/// Lightweight interaction profiler. Emits os_log events on a dedicated subsystem
/// so we can watch real clicks/tab-switches with timestamps & durations via:
///
///   log stream --predicate 'subsystem == "com.claudoscope.perf"' --style compact
///
/// Zero-cost in normal use beyond a single os_log call per instrumented event.
enum PerfLog {
    static let log = Logger(subsystem: "com.claudoscope.perf", category: "interaction")

    /// Emit a pre-formatted event string (public so it isn't redacted in logs).
    static func event(_ message: String) {
        log.log("\(message, privacy: .public)")
    }
}

/// Logs the wall time from view-struct creation to on-screen appearance — a proxy
/// for SwiftUI build+layout cost. A laggy rail/tab switch shows up as a large value.
struct PerfRenderTimer: ViewModifier {
    let label: String
    private let created = CFAbsoluteTimeGetCurrent()
    func body(content: Content) -> some View {
        content.onAppear {
            PerfLog.event(String(format: "render %@ %.1fms", label, (CFAbsoluteTimeGetCurrent() - created) * 1000))
        }
    }
}

extension View {
    /// Mark a view for render-time logging (see `PerfRenderTimer`).
    func perfRender(_ label: String) -> some View { modifier(PerfRenderTimer(label: label)) }
}
