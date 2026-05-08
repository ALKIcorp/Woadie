import Foundation

enum AppConfig {
    static let kokoroPath = "/Volumes/ALKI SD/MACBOOK PRO STORAGE/ALKI Corp Dev/tts/kokoro"
    static let enginePort = 7777
    static let serverBaseURL = URL(string: "http://127.0.0.1:\(enginePort)")!
    static let defaultVoice = "af_heart"
    static let defaultRate = 24000
    static let healthTimeoutSeconds: TimeInterval = 20
}
