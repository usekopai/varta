import Foundation
import VartaCore

/// Appends to ~/.varta/app.log so a failed command can be traced after the fact.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".varta/app.log")
    private static let queue = DispatchQueue(label: "varta.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func timing(_ sample: CommandTiming.Sample) {
        guard let data = try? JSONEncoder().encode(sample), let json = String(data: data, encoding: .utf8) else { return }
        write("timing " + json)
    }
    static func write(_ message: String) {
        let timestamp = Date()
        queue.async {
            let line = "\(stamp.string(from: timestamp)) \(message)\n"
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
