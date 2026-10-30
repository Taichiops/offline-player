import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    /// Path relative to the Documents folder. Never store the full path:
    /// the app container path changes between installs.
    var fileName: String
    var title: String
    var artist: String?
    var duration: Double?

    var url: URL {
        URL.documentsDirectory.appendingPathComponent(fileName)
    }
}

extension Double {
    /// "3:07" or "1:02:45".
    var clockString: String {
        guard isFinite, self > 0 else { return "0:00" }
        let pattern: Duration.TimeFormatStyle.Pattern = self >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(self).formatted(.time(pattern: pattern))
    }
}
