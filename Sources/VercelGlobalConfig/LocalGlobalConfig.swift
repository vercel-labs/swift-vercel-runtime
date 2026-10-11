#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization

/// A snapshot of a store that Vercel ships with the deployment as `/opt/edge-config/<id>.json`:
/// `{"digest": "…", "updatedAt": …, "items": {…}}`.
struct LocalGlobalConfig: Sendable, Decodable {
    var digest: String
    var items: [String: GlobalConfigValue]

    private enum Entry {
        case present(LocalGlobalConfig)
        case absent
    }

    /// Snapshots by path. Each file is read at most once per process: deployments never change it.
    private static let cache = Mutex<[String: Entry]>([:])

    /// The snapshot at `path`, or `nil` when the file is missing or malformed.
    static func load(path: String) -> LocalGlobalConfig? {
        let cached = cache.withLock { $0[path] }
        let entry: Entry
        if let cached {
            entry = cached
        } else {
            let read = read(path: path).map(Entry.present) ?? .absent
            entry = cache.withLock { cache in
                if let existing = cache[path] { return existing }
                cache[path] = read
                return read
            }
        }
        switch entry {
        case .present(let snapshot): return snapshot
        case .absent: return nil
        }
    }

    private static func read(path: String) -> LocalGlobalConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(LocalGlobalConfig.self, from: data)
    }
}
