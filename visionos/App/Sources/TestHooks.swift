import Foundation

// The environment variables that drive headless Simulator test runs (docs/DEVELOPING.md). They
// exist only in Simulator builds: an app installed on a headset ignores them. Set but empty counts
// as not set, so a test script can pass every hook and leave the ones it doesn't need blank.
enum TestHooks {
    static func value(_ name: String) -> String? {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }
}
