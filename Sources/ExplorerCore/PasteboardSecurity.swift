import Foundation

public enum PasteboardSecurity {
    public static func isAppOwned(_ urls: [URL], changeCountBefore: Int, changeCountAfter: Int,
                                  ownedURLs: [URL], ownedChangeCount: Int?) -> Bool {
        guard let ownedChangeCount, changeCountBefore == changeCountAfter,
              changeCountAfter == ownedChangeCount else { return false }
        return Set(urls.map(\.standardizedFileURL)) == Set(ownedURLs.map(\.standardizedFileURL))
    }

}
