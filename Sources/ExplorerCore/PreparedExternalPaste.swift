import Foundation
import Darwin

private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private func actualPath(of descriptor: Int32) throws -> String {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw posixError() }
    return String(cString: path)
}

private func linkTarget(in directory: Int32, name: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
    let length = readlinkat(directory, name, &buffer, buffer.count - 1)
    guard length >= 0 else { throw posixError() }
    guard length < buffer.count - 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG)) }
    return String(cString: buffer)
}

private func sameFile(_ first: Int32, _ second: Int32) throws -> Bool {
    var a = stat(), b = stat()
    guard fstat(first, &a) == 0, fstat(second, &b) == 0 else { throw posixError() }
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

private final class ExternalSource {
    enum Kind { case file, directory, link(String) }
    let name: String
    let path: String
    let kind: Kind
    let descriptor: Int32

    init(_ url: URL) throws {
        name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != "..", !name.contains("\0") else {
            throw FileOperationError.invalidName
        }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw posixError() }
        defer { Darwin.close(parent) }
        let opened = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if opened < 0 {
            guard errno == ELOOP else { throw posixError() }
            let target = try linkTarget(in: parent, name: name)
            path = try actualPath(of: parent) + "/" + name
            kind = .link(target)
            descriptor = -1
            return
        }
        var info = stat()
        guard fstat(opened, &info) == 0 else {
            let error = posixError(); Darwin.close(opened); throw error
        }
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .file
        case mode_t(S_IFDIR): kind = .directory
        default:
            Darwin.close(opened)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFTYPE))
        }
        do { path = try actualPath(of: opened) }
        catch { Darwin.close(opened); throw error }
        descriptor = opened
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    var displayDescription: String {
        switch kind {
        case .file: return String(reflecting: path)
        case .directory: return String(reflecting: path) + "（フォルダー内を含む）"
        case .link(let target): return String(reflecting: path) + " → " + String(reflecting: target)
        }
    }
}

public final class PreparedExternalPaste {
    private let sources: [ExternalSource]
    private let destinationDescriptor: Int32
    public let destinationURL: URL
    public let preparationFailures: [String]
    public var sourceDescriptions: [String] { sources.map(\.displayDescription) }
    public var sourceCount: Int { sources.count }

    public init(_ urls: [URL], to destination: URL) throws {
        let opened = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY)
        guard opened >= 0 else { throw posixError() }
        do { destinationURL = URL(fileURLWithPath: try actualPath(of: opened), isDirectory: true) }
        catch { Darwin.close(opened); throw error }
        destinationDescriptor = opened
        var prepared: [ExternalSource] = []
        var failures: [String] = []
        for url in FileService.topLevelURLs(urls) {
            do {
                let source = try ExternalSource(url)
                if case .directory = source.kind,
                   (destinationURL.path == source.path || destinationURL.path.hasPrefix(source.path + "/")) {
                    throw FileOperationError.recursiveDestination
                }
                prepared.append(source)
            }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        sources = prepared
        preparationFailures = failures
    }

    deinit { Darwin.close(destinationDescriptor) }

    public func transfer() -> TransferResult {
        var result = TransferResult()
        result.failures = preparationFailures
        for source in sources {
            do {
                let name = try copy(source)
                result.completed.append(destinationURL.appendingPathComponent(name))
            } catch { result.failures.append("\(source.name): \(error.localizedDescription)") }
        }
        return result
    }

    private func copy(_ source: ExternalSource) throws -> String {
        let original = URL(fileURLWithPath: source.name)
        let ext = original.pathExtension
        let stem = ext.isEmpty ? source.name : original.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let name = index == 1 ? source.name : "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            switch source.kind {
            case .file:
                let output = openat(destinationDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                if output < 0 {
                    if errno == EEXIST { index += 1; continue }
                    throw posixError()
                }
                defer { Darwin.close(output) }
                if fcopyfile(source.descriptor, output, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 {
                    let error = posixError()
                    unlinkat(destinationDescriptor, name, 0)
                    throw error
                }
            case .directory:
                if mkdirat(destinationDescriptor, name, 0o700) != 0 {
                    if errno == EEXIST { index += 1; continue }
                    throw posixError()
                }
                let output = openat(destinationDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard output >= 0 else { throw posixError() }
                defer { Darwin.close(output) }
                try copyDirectory(from: source.descriptor, to: output)
                if fcopyfile(source.descriptor, output, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 { throw posixError() }
            case .link(let target):
                if symlinkat(target, destinationDescriptor, name) != 0 {
                    if errno == EEXIST { index += 1; continue }
                    throw posixError()
                }
            }
            return name
        }
    }

    private func copyDirectory(from source: Int32, to destination: Int32) throws {
        if try sameFile(source, destinationDescriptor) { throw FileOperationError.recursiveDestination }
        let duplicate = dup(source)
        guard duplicate >= 0 else { throw posixError() }
        guard let stream = fdopendir(duplicate) else {
            let error = posixError(); Darwin.close(duplicate); throw error
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if input < 0 {
                guard errno == ELOOP else { throw posixError() }
                let target = try linkTarget(in: source, name: name)
                guard symlinkat(target, destination, name) == 0 else { throw posixError() }
                continue
            }
            defer { Darwin.close(input) }
            var info = stat()
            guard fstat(input, &info) == 0 else { throw posixError() }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG):
                let output = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard output >= 0 else { throw posixError() }
                defer { Darwin.close(output) }
                guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw posixError() }
            case mode_t(S_IFDIR):
                guard mkdirat(destination, name, 0o700) == 0 else { throw posixError() }
                let output = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard output >= 0 else { throw posixError() }
                defer { Darwin.close(output) }
                try copyDirectory(from: input, to: output)
                guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw posixError() }
            default:
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFTYPE))
            }
        }
    }
}
