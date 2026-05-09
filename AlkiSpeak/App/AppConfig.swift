import Foundation

enum AppConfig {
    /// Directory containing `kokoro_server.py` and `.venv`. Override with env `KOKORO_HOME` when the repo lives elsewhere.
    static var kokoroPath: String {
        if let env = ProcessInfo.processInfo.environment["KOKORO_HOME"], !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "/Volumes/ALKI SD/MACBOOK PRO STORAGE/ALKI Corp Dev/tts/kokoro"
    }
    static let enginePort = 7777
    static let serverBaseURL = URL(string: "http://127.0.0.1:\(enginePort)")!
    static let defaultVoice = "af_heart"
    static let defaultRate = 24000
    static let engineStartupTimeoutSeconds: TimeInterval = 180
    static let requestTimeoutSeconds: TimeInterval = 45
    static let resourceTimeoutSeconds: TimeInterval = 10
    static let healthCheckTimeoutSeconds: TimeInterval = 3
    static let healthCheckIntervalSeconds: TimeInterval = 5
    static let maxEngineRestartAttempts = 3
    static let maxDirectRequestCharacters = 1_800
    static let maxSegmentCharacters = 1_200
    static let maxBufferedDiagnostics = 80
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
