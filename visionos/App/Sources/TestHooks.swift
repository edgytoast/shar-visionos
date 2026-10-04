import Foundation

// The environment variables that drive headless Simulator test runs (docs/DEVELOPING.md). They
// exist only in Simulator builds: an app installed on a headset ignores them.
enum TestHooks {
    static func value(_ name: String) -> String? {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[name]
        #else
        nil
        #endif
    }
}
