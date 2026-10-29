import Foundation
import ExplorerCore
import Darwin

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ value: @autoclosure () throws -> Bool, file: String = #filePath, line: Int = #line) throws {
    if try !value() { throw CheckFailure(description: "Assertion failed at \(file):\(line)") }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, file: String = #filePath, line: Int = #line) throws {
    try expect(try !value(), file: file, line: line)
}
func expectEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: String = #filePath, line: Int = #line) throws {
    let a = try left(), b = try right()
    if a != b { throw CheckFailure(description: "Expected \(b), got \(a) at \(file):\(line)") }
}
func expectThrows<T>(_ body: @autoclosure () throws -> T, file: String = #filePath, line: Int = #line) throws {
    do { _ = try body() } catch { return }
    throw CheckFailure(description: "Expected an error at \(file):\(line)")
}

final class FileServiceTests {
    var root: URL!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ExpMosTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult func file(_ name: String, contents: String = "original", in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func testCopyCollisionPreservesBothContents() throws {
        let source = try file("report.txt", contents: "source")
        let destination = try FileService.createFolder(in: root, name: "destination")
        let existing = try file("report.txt", contents: "destination", in: destination)
        let result = FileService.transfer([source], to: destination, move: false)
        try expect(result.failures.isEmpty)
        try expectEqual(result.completed.first?.lastPathComponent, "report (2).txt")
        try expectEqual(try String(contentsOf: existing, encoding: .utf8), "destination")
        try expectEqual(try String(contentsOf: result.completed[0], encoding: .utf8), "source")
        try expect(FileManager.default.fileExists(atPath: source.path))
    }
    func testCutMovesAndPreservesDestination() throws {
        let source = try file("note.txt", contents: "moved")
        let destination = try FileService.createFolder(in: root, name: "destination")
        let existing = try file("note.txt", contents: "keep", in: destination)
        let result = FileService.transfer([source], to: destination, move: true)
        try expect(result.failures.isEmpty)
        try expectFalse(FileManager.default.fileExists(atPath: source.path))
        try expectEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        try expectEqual(try String(contentsOf: result.completed[0], encoding: .utf8), "moved")
    }
    func testRejectsSelfAndDescendantTransfersIncludingSymlink() throws {
        let folder = try FileService.createFolder(in: root, name: "folder")
        let child = try FileService.createFolder(in: folder, name: "child")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        for destination in [folder, child, link] {
            let result = FileService.transfer([folder], to: destination, move: false)
            try expect(result.completed.isEmpty)
            try expectEqual(result.failures.count, 1)
        }
        try expect(FileManager.default.fileExists(atPath: child.path))
    }
    func testMoveToSameFolderDoesNotRenameSource() throws {
        let source = try file("same.txt")
        let result = FileService.transfer([source], to: root, move: true)
        try expect(result.completed.isEmpty)
        try expectEqual(result.failures.count, 1)
        try expect(FileManager.default.fileExists(atPath: source.path))
    }
    func testRenameRejectsOverwriteAndInvalidNames() throws {
        let source = try file("source.txt")
        let existing = try file("keep.txt", contents: "keep")
        try expectThrows(try FileService.rename(source, to: "keep.txt"))
        for name in ["", ".", "..", "../escape", "a/b", "a:b", "\0", "   "] {
            try expectThrows(try FileService.rename(source, to: name))
            try expectThrows(try FileService.createFolder(in: root, name: name))
        }
        try expectEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        try expect(FileManager.default.fileExists(atPath: source.path))
    }
    func testPartialFailureReportsAndKeepsSuccessfulCopy() throws {
        let source = try file("good.txt")
        let destination = try FileService.createFolder(in: root, name: "destination")
        let result = FileService.transfer([source, root.appendingPathComponent("missing")], to: destination, move: false)
        try expectEqual(result.completed.count, 1)
        try expectEqual(result.failures.count, 1)
        try expect(FileManager.default.fileExists(atPath: source.path))
    }
    func testSelectedDescendantsAreOnlyTransferredOnce() throws {
        try expectEqual(FileService.topLevelURLs([URL(fileURLWithPath: "/"), root]).map(\.path), ["/"])
        let folder = try FileService.createFolder(in: root, name: "folder")
        let child = try file("child.txt", in: folder)
        let destination = try FileService.createFolder(in: root, name: "destination")
        let result = FileService.transfer([folder, child, folder], to: destination, move: false)
        try expectEqual(result.completed.count, 1)
        try expect(result.failures.isEmpty)
        try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder/child.txt").path))
    }
    func testHiddenFileSetting() throws {
        try file("visible.txt"); try file(".hidden")
        try expectEqual(try FileService.list(root, showHidden: false).map(\.name), ["visible.txt"])
        try expectEqual(try FileService.list(root, showHidden: true).count, 2)
    }
    func testHistoryBranchDropsForwardHistoryAndNormalizesPaths() throws {
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        let c = URL(fileURLWithPath: "/tmp/c")
        var history = NavigationHistory(a)
        history.visit(b); history.visit(c); history.back()
        try expectEqual(history.current, b)
        try expect(history.canGoForward)
        history.visit(a)
        try expectFalse(history.canGoForward)
        try expectEqual(history.locations.count, 3)
        history.visit(URL(fileURLWithPath: "/tmp/a/../a"))
        try expectEqual(history.locations.count, 3)
        history.back(); history.forward()
        try expectEqual(history.current, a)
    }
    func testPasteboardOwnershipRequiresUnchangedMatchingClipboard() throws {
        let own = root.appendingPathComponent("own.txt")
        let injected = root.appendingPathComponent("injected.txt")
        try expect(PasteboardSecurity.isAppOwned([own], changeCountBefore: 3, changeCountAfter: 3,
            ownedURLs: [own], ownedChangeCount: 3))
        try expectFalse(PasteboardSecurity.isAppOwned([injected], changeCountBefore: 3, changeCountAfter: 3,
            ownedURLs: [own], ownedChangeCount: 3))
        try expectFalse(PasteboardSecurity.isAppOwned([own], changeCountBefore: 4, changeCountAfter: 4,
            ownedURLs: [own], ownedChangeCount: 3))
        try expectFalse(PasteboardSecurity.isAppOwned([own], changeCountBefore: 3, changeCountAfter: 4,
            ownedURLs: [own], ownedChangeCount: 3))
        try expectFalse(PasteboardSecurity.isAppOwned([own], changeCountBefore: 3, changeCountAfter: 3,
            ownedURLs: [], ownedChangeCount: nil))
    }
    func testExternalPasteKeepsApprovedFileAcrossParentSwap() throws {
        let stage = try FileService.createFolder(in: root, name: "stage")
        let protected = try FileService.createFolder(in: root, name: "protected")
        let destination = try FileService.createFolder(in: root, name: "destination")
        let source = try file("secret.txt", contents: "approved", in: stage)
        try file("secret.txt", contents: "protected", in: protected)
        let prepared = try PreparedExternalPaste([source], to: destination)
        try expectEqual(prepared.sourceCount, 1)
        try expect(prepared.sourceDescriptions[0].contains(stage.path))
        try FileManager.default.moveItem(at: stage, to: root.appendingPathComponent("stage-old"))
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: protected)
        let result = prepared.transfer()
        try expect(result.failures.isEmpty)
        try expectEqual(try String(contentsOf: result.completed[0], encoding: .utf8), "approved")
    }
    func testExternalPasteCopiesDirectoryAndLink() throws {
        let source = try FileService.createFolder(in: root, name: "source")
        try file("child.txt", contents: "child", in: source)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let destination = try FileService.createFolder(in: root, name: "destination")
        let prepared = try PreparedExternalPaste([source, link], to: destination)
        let result = prepared.transfer()
        try expect(result.failures.isEmpty)
        try expectEqual(try String(contentsOf: destination.appendingPathComponent("source/child.txt"), encoding: .utf8), "child")
        try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path), source.path)
    }
    func testExternalPasteKeepsApprovedFolderAcrossParentSwap() throws {
        let stage = try FileService.createFolder(in: root, name: "stage")
        let approved = try FileService.createFolder(in: stage, name: "folder")
        try file("child.txt", contents: "approved", in: approved)
        let protected = try FileService.createFolder(in: root, name: "protected")
        let replacement = try FileService.createFolder(in: protected, name: "folder")
        try file("child.txt", contents: "protected", in: replacement)
        let destination = try FileService.createFolder(in: root, name: "destination")
        let prepared = try PreparedExternalPaste([approved], to: destination)
        try FileManager.default.moveItem(at: stage, to: root.appendingPathComponent("stage-old"))
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: protected)
        let result = prepared.transfer()
        try expect(result.failures.isEmpty)
        try expectEqual(try String(contentsOf: destination.appendingPathComponent("folder/child.txt"), encoding: .utf8), "approved")
    }
    func testExternalPasteKeepsDestinationAndAvoidsOverwrite() throws {
        let source = try file("source.txt", contents: "source")
        let destination = try FileService.createFolder(in: root, name: "destination")
        try file("source.txt", contents: "keep", in: destination)
        let prepared = try PreparedExternalPaste([source], to: destination)
        let moved = root.appendingPathComponent("moved-destination")
        try FileManager.default.moveItem(at: destination, to: moved)
        let replacement = try FileService.createFolder(in: root, name: "replacement")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: replacement)
        let result = prepared.transfer()
        try expect(result.failures.isEmpty)
        try expectEqual(try String(contentsOf: moved.appendingPathComponent("source.txt"), encoding: .utf8), "keep")
        try expectEqual(try String(contentsOf: moved.appendingPathComponent("source (2).txt"), encoding: .utf8), "source")
        try expectFalse(FileManager.default.fileExists(atPath: replacement.appendingPathComponent("source (2).txt").path))
    }
    func testExternalPasteRejectsRecursiveDirectory() throws {
        let source = try FileService.createFolder(in: root, name: "source")
        let child = try FileService.createFolder(in: source, name: "child")
        let prepared = try PreparedExternalPaste([source], to: child)
        try expectEqual(prepared.sourceCount, 0)
        try expectEqual(prepared.preparationFailures.count, 1)
        try expectFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("source").path))
    }
    func testExternalPasteStopsWhenDestinationMovesIntoSource() throws {
        let source = try FileService.createFolder(in: root, name: "source")
        let destination = try FileService.createFolder(in: root, name: "destination")
        let prepared = try PreparedExternalPaste([source], to: destination)
        try FileManager.default.moveItem(at: destination, to: source.appendingPathComponent("destination"))
        let result = prepared.transfer()
        try expect(result.completed.isEmpty)
        try expectEqual(result.failures.count, 1)
    }
    func testExternalPasteRejectsSpecialFile() throws {
        let pipe = root.appendingPathComponent("pipe")
        try expectEqual(mkfifo(pipe.path, 0o600), 0)
        let destination = try FileService.createFolder(in: root, name: "destination")
        let prepared = try PreparedExternalPaste([pipe], to: destination)
        try expectEqual(prepared.sourceCount, 0)
        try expectEqual(prepared.preparationFailures.count, 1)
    }
}


@main struct CoreChecks {
    static func main() throws {
        let tests = FileServiceTests()
        let cases: [(String, () throws -> Void)] = [
            ("Copy collision preserves both contents", tests.testCopyCollisionPreservesBothContents),
            ("Cut moves and preserves destination", tests.testCutMovesAndPreservesDestination),
            ("Reject self, descendant and symlink recursion", tests.testRejectsSelfAndDescendantTransfersIncludingSymlink),
            ("Same-directory move preserves source name", tests.testMoveToSameFolderDoesNotRenameSource),
            ("Rename and folder name validation", tests.testRenameRejectsOverwriteAndInvalidNames),
            ("Partial failure preserves successful copies", tests.testPartialFailureReportsAndKeepsSuccessfulCopy),
            ("Selected descendants transfer once", tests.testSelectedDescendantsAreOnlyTransferredOnce),
            ("Hidden file filtering", tests.testHiddenFileSetting),
            ("History branches and path normalization", tests.testHistoryBranchDropsForwardHistoryAndNormalizesPaths),
            ("Pasteboard ownership rejects changed or injected URLs", tests.testPasteboardOwnershipRequiresUnchangedMatchingClipboard),
            ("External paste binds approved source across parent swap", tests.testExternalPasteKeepsApprovedFileAcrossParentSwap),
            ("External paste preserves directories and links", tests.testExternalPasteCopiesDirectoryAndLink),
            ("External paste binds approved folder across parent swap", tests.testExternalPasteKeepsApprovedFolderAcrossParentSwap),
            ("External paste binds destination and avoids overwrite", tests.testExternalPasteKeepsDestinationAndAvoidsOverwrite),
            ("External paste rejects recursive directory", tests.testExternalPasteRejectsRecursiveDirectory),
            ("External paste stops late destination recursion", tests.testExternalPasteStopsWhenDestinationMovesIntoSource),
            ("External paste rejects special file", tests.testExternalPasteRejectsSpecialFile)
        ]
        var failures = 0
        for (name, body) in cases {
            try tests.setUpWithError()
            do { try body(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
            try tests.tearDownWithError()
        }
        print("\(cases.count - failures)/\(cases.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
