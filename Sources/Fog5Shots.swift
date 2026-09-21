import Foundation

/// THROWAWAY (branch claude/fog5-shots only, never main): render the scan screen in the simulator.
enum Fog5 {
    static let on = ProcessInfo.processInfo.arguments.contains("-fog5shots")
    static let white = ProcessInfo.processInfo.arguments.contains("-fog5white")
    static let banner = ProcessInfo.processInfo.arguments.contains("-fog5banner")
}
