import Foundation

public struct FileEntry: Identifiable {
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?
    public let kind: String
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
        isDirectory = values?.isDirectory ?? false
        size = Int64(values?.fileSize ?? 0)
        modified = values?.contentModificationDate
        kind = values?.localizedTypeDescription ?? (isDirectory ? "フォルダー" : "ファイル")
    }
}

public enum FileOperationError: LocalizedError {
    case invalidName, alreadyExists(String), recursiveDestination, sameLocation, missingSource(String)
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "名前に / や : は使えません。空の名前、.、.. も指定できません。"
        case .alreadyExists(let name): return "「\(name)」はすでに存在します。上書きはしていません。"
        case .recursiveDestination: return "フォルダーを自分自身やその中へコピー・移動することはできません。"
        case .sameLocation: return "移動先が元のフォルダーと同じです。"
        case .missingSource(let name): return "「\(name)」が見つかりません。"
        }
    }
}

public struct TransferResult {
    public var completed: [URL] = []
    public var failures: [String] = []
    public init() {}
}

public enum FileService {
    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }
    public static func list(_ directory: URL, showHidden: Bool) throws -> [FileEntry] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey],
            options: showHidden ? [] : [.skipsHiddenFiles]).map(FileEntry.init)
    }

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw FileOperationError.invalidName
        }
    }

    public static func availableURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        let base = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: base.path) { return base }
        let ext = base.pathExtension
        let stem = ext.isEmpty ? name : base.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    @discardableResult public static func createFolder(in directory: URL, name: String) throws -> URL {
        try validateName(name)
        let target = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileOperationError.alreadyExists(name) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    @discardableResult public static func rename(_ source: URL, to name: String) throws -> URL {
        try validateName(name)
        if source.lastPathComponent == name { return source }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileOperationError.alreadyExists(name) }
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    // Process parents before children and suppress selected descendants, so a selection
    // containing both a folder and its child never transfers or trashes the child twice.
    public static func topLevelURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in Set(urls.map { $0.standardizedFileURL }).sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { contains($0.path, url.path) }) { result.append(url) }
        }
        return result
    }

    public static func transfer(_ sources: [URL], to directory: URL, move: Bool) -> TransferResult {
        var result = TransferResult()
        let fm = FileManager.default
        for source in topLevelURLs(sources) {
            do {
                guard fm.fileExists(atPath: source.path) else { throw FileOperationError.missingSource(source.lastPathComponent) }
                let realSource = source.resolvingSymlinksInPath().standardizedFileURL.path
                let realDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
                if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                   contains(realSource, realDirectory) {
                    throw FileOperationError.recursiveDestination
                }
                if move && source.deletingLastPathComponent().resolvingSymlinksInPath().path == realDirectory {
                    throw FileOperationError.sameLocation
                }
                // A numbered name preserves both files on collision. FileManager also
                // refuses overwrites if a destination appears after this check.
                let destination = availableURL(in: directory, name: source.lastPathComponent)
                if move { try fm.moveItem(at: source, to: destination) }
                else { try fm.copyItem(at: source, to: destination) }
                result.completed.append(destination)
            } catch { result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }
}

public struct NavigationHistory {
    public private(set) var locations: [URL]
    public private(set) var index = 0
    public var current: URL { locations[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < locations.count }
    public init(_ url: URL) { locations = [url.standardizedFileURL] }
    public mutating func visit(_ url: URL) {
        let next = url.standardizedFileURL
        guard next != current else { return }
        locations = Array(locations.prefix(index + 1)) + [next]
        index = locations.count - 1
    }
    public mutating func back() { if canGoBack { index -= 1 } }
    public mutating func forward() { if canGoForward { index += 1 } }
}
