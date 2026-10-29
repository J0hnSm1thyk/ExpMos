import AppKit
import ExplorerCore
import UniformTypeIdentifiers
import Darwin

enum Theme {
    static let ink = NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.24, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.49, green: 0.53, blue: 0.56, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.13, green: 0.43, blue: 0.38, alpha: 1)
    static let sidebar = NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.95, alpha: 1)
    static let line = NSColor(calibratedRed: 0.89, green: 0.91, blue: 0.90, alpha: 1)
    static let tint = NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.91, alpha: 1)
}

func symbol(_ name: String, size: CGFloat = 15) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
}
func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Theme.ink) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    return field
}
func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = vertical ? .vertical : .horizontal
    view.alignment = vertical ? .leading : .centerY
    view.spacing = spacing
    return view
}
func box(_ color: NSColor, radius: CGFloat = 0) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = color.cgColor
    view.layer?.cornerRadius = radius
    return view
}
func constrain(_ view: NSView, in parent: NSView, top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
    view.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: left),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -bottom),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -right)
    ])
}

final class ExplorerTable: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if row < 0 { deselectAll(nil) }
        return super.menu(for: event)
    }
}

// Keep window actions inside our content, away from the system sharing badge.
final class WindowControlButton: NSButton {
    private let closesWindow: Bool
    private var hoverArea: NSTrackingArea?

    init(icon: String, label: String, closesWindow: Bool = false, target: AnyObject, action: Selector) {
        self.closesWindow = closesWindow
        super.init(frame: .zero)
        self.target = target
        self.action = action
        image = symbol(icon, size: 13)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = Theme.ink
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 39),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = (closesWindow ? NSColor.systemRed : Theme.line).cgColor
        contentTintColor = closesWindow ? .white : Theme.ink
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = Theme.ink
    }
}

final class FolderNode: NSObject {
    let title: String
    let url: URL?
    let icon: String
    let heading: Bool
    var children: [FolderNode]?
    init(_ title: String, url: URL? = nil, icon: String = "folder", heading: Bool = false, children: [FolderNode]? = nil) {
        self.title = title; self.url = url; self.icon = icon; self.heading = heading; self.children = children
    }
    func load(hidden: Bool) -> [FolderNode] {
        if let children { return children }
        guard let url else { return [] }
        let entries = (try? FileService.list(url, showHidden: hidden)) ?? []
        let folders = entries.filter { $0.isDirectory && !NSWorkspace.shared.isFilePackage(atPath: $0.url.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        children = folders.map { FolderNode($0.name, url: $0.url) }
        return children ?? []
    }
    func invalidate() {
        if !heading { children = nil }
        else { children?.forEach { $0.invalidate() } }
    }
}

final class FolderTab {
    let id = UUID()
    var history: NavigationHistory
    var query = ""
    var selection: Set<URL> = []
    init(_ url: URL) { history = NavigationHistory(url) }
}

final class ExplorerController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let table = ExplorerTable()
    let outline = NSOutlineView()
    let pathField = NSTextField()
    let searchField = NSSearchField()
    let titleLabel = label("ホーム", size: 24, weight: .semibold)
    let subtitleLabel = label("", size: 11, color: Theme.muted)
    let statusLabel = label("", size: 11, color: Theme.muted)
    let selectionLabel = label("", size: 11, color: Theme.muted)
    let emptyTitle = label("このフォルダーは空です", size: 17, weight: .medium)
    let emptySubtitle = label("新規フォルダーを作成するか、項目を貼り付けてください。", size: 12, color: Theme.muted)
    let tabStack = NSStackView()
    let emptyView = NSStackView()
    let progress = NSProgressIndicator()
    var backButton: NSButton!
    var forwardButton: NSButton!
    var upButton: NSButton!
    var pasteButton: NSButton!
    var hiddenButton: NSButton!
    var maximizeButton: WindowControlButton!
    var closeWindowButton: WindowControlButton!
    var frameBeforeMaximizing: NSRect?
    var tabs: [FolderTab] = []
    var activeIndex = 0
    var currentTab: FolderTab { tabs[activeIndex] }
    var directory: URL { currentTab.history.current }
    var entries: [FileEntry] = []
    var visibleEntries: [FileEntry] = []
    var showHidden = UserDefaults.standard.bool(forKey: "showHidden")
    var roots: [FolderNode] = []
    var cutURLs: [URL] = []
    var cutChangeCount: Int = -1
    var ownedClipboardURLs: [URL] = []
    var ownedClipboardChangeCount: Int?
    var watcher: DispatchSourceFileSystemObject?
    var busy = false
    var updatingTable = false
    var clipboardTimer: Timer?
    var errorMessage: String?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ExpMos"
        window.minSize = NSSize(width: 940, height: 580)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ExpMos.Main")
        super.init(window: window)
        window.delegate = self
        let saved = UserDefaults.standard.stringArray(forKey: "tabPaths") ?? []
        let restored = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
        tabs = (restored.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : Array(restored.prefix(20))).map(FolderTab.init)
        activeIndex = min(UserDefaults.standard.integer(forKey: "activeTab"), tabs.count - 1)
        buildUI()
        buildSidebar()
        refresh()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.updateClipboard() }
        window.center()
        updateWindowControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    func button(_ title: String, icon: String? = nil, action: Selector, tooltip: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = Theme.ink
        if let icon { button.image = symbol(icon); button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        button.toolTip = tooltip ?? title
        button.setAccessibilityLabel(tooltip ?? title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if title.isEmpty { button.widthAnchor.constraint(equalToConstant: 32).isActive = true }
        return button
    }

    func buildUI() {
        guard let content = window?.contentView else { return }
        let sidebar = box(Theme.sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor), sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.widthAnchor.constraint(equalToConstant: 228)
        ])
        let mark = NSImageView(image: symbol("square.split.2x2.fill", size: 24)!)
        mark.contentTintColor = Theme.accent
        let brand = stack([mark, label("ExpMos", size: 21, weight: .semibold)], spacing: 10)
        brand.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(brand)
        NSLayoutConstraint.activate([brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 28), brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22)])
        let tagline = label("いつもの操作で、Macを自由に。", size: 10, color: Theme.muted)
        tagline.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tagline)
        NSLayoutConstraint.activate([tagline.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 8), tagline.leadingAnchor.constraint(equalTo: brand.leadingAnchor)])

        let outlineColumn = NSTableColumn(identifier: .init("folders"))
        outline.addTableColumn(outlineColumn)
        outline.outlineTableColumn = outlineColumn
        outline.headerView = nil
        outline.rowHeight = 30
        outline.indentationPerLevel = 15
        // Avoid the system source-list material so the entire sidebar has one color.
        outline.style = .plain
        outline.backgroundColor = Theme.sidebar
        outline.floatsGroupRows = false
        outline.focusRingType = .none
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.action = #selector(sidebarClicked)
        let treeScroll = NSScrollView()
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.backgroundColor = Theme.sidebar
        treeScroll.drawsBackground = true
        treeScroll.contentView.backgroundColor = Theme.sidebar
        treeScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(treeScroll)
        let disk = label("", size: 10, color: Theme.muted)
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey]), let capacity = values.volumeAvailableCapacity {
            disk.stringValue = "Macintosh HD  ·  空き \(ByteCountFormatter.string(fromByteCount: Int64(capacity), countStyle: .file))"
        } else { disk.stringValue = "このMac" }
        disk.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(disk)
        NSLayoutConstraint.activate([
            treeScroll.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 26), treeScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            treeScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8), treeScroll.bottomAnchor.constraint(equalTo: disk.topAnchor, constant: -16),
            disk.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22), disk.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            disk.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -17)
        ])

        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(main)
        NSLayoutConstraint.activate([main.topAnchor.constraint(equalTo: content.topAnchor), main.bottomAnchor.constraint(equalTo: content.bottomAnchor), main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), main.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
        let column = stack([], vertical: true, spacing: 0)
        column.alignment = .width
        constrain(column, in: main)

        let tabBar = box(NSColor(calibratedWhite: 0.98, alpha: 1))
        tabBar.heightAnchor.constraint(equalToConstant: 47).isActive = true
        tabStack.orientation = .horizontal; tabStack.spacing = 5; tabStack.alignment = .centerY
        let tabScroll = NSScrollView()
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.documentView = tabStack
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabScroll)
        let add = button("", icon: "plus", action: #selector(newTab), tooltip: "新しいタブ（⌘T）")
        tabBar.addSubview(add)
        let minimize = WindowControlButton(icon: "minus", label: "ウィンドウを最小化（⌘M）", target: self, action: #selector(minimizeWindow))
        maximizeButton = WindowControlButton(icon: "rectangle", label: "ウィンドウを最大化", target: self, action: #selector(toggleMaximizeWindow))
        closeWindowButton = WindowControlButton(icon: "xmark", label: "ウィンドウを閉じる（⌘⇧W）", closesWindow: true, target: self, action: #selector(closeWindow))
        let controls = stack([minimize, maximizeButton, closeWindowButton], spacing: 2)
        controls.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(controls)
        let separator = divider()
        tabBar.addSubview(separator)
        NSLayoutConstraint.activate([
            tabScroll.topAnchor.constraint(equalTo: tabBar.topAnchor, constant: 6), tabScroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: -4),
            tabScroll.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 15), tabScroll.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -6),
            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor), tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStack.heightAnchor.constraint(equalToConstant: 34),
            add.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -9), add.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            separator.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -9), separator.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -10), controls.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor)
        ])
        column.addArrangedSubview(tabBar)

        let header = NSView()
        header.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let titles = stack([titleLabel, subtitleLabel], vertical: true, spacing: 6)
        titles.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titles)
        searchField.placeholderString = "このフォルダー内を検索"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(searchField)
        NSLayoutConstraint.activate([
            titles.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 26), titles.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: searchField.leadingAnchor, constant: -20),
            searchField.widthAnchor.constraint(equalToConstant: 236), searchField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor), searchField.heightAnchor.constraint(equalToConstant: 30)
        ])
        column.addArrangedSubview(header)

        backButton = button("", icon: "chevron.left", action: #selector(goBack), tooltip: "戻る（⌘[ / ⌥←）")
        forwardButton = button("", icon: "chevron.right", action: #selector(goForward), tooltip: "進む（⌘] / ⌥→）")
        upButton = button("", icon: "arrow.up", action: #selector(goUp), tooltip: "親フォルダーへ（⌘↑ / ⌥↑）")
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.textColor = Theme.ink
        pathField.bezelStyle = .roundedBezel
        pathField.focusRingType = .exterior
        pathField.target = self; pathField.action = #selector(pathEntered)
        pathField.setAccessibilityLabel("フォルダーのパス")
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.heightAnchor.constraint(equalToConstant: 31).isActive = true
        let reload = button("", icon: "arrow.clockwise", action: #selector(reloadFolder), tooltip: "更新（⌘R / F5）")
        let address = stack([backButton, forwardButton, upButton, pathField, reload], spacing: 3)
        let addressBox = NSView()
        addressBox.heightAnchor.constraint(equalToConstant: 46).isActive = true
        constrain(address, in: addressBox, top: 4, left: 21, bottom: 11, right: 19)
        column.addArrangedSubview(addressBox)

        let newFolder = button("新規フォルダー", icon: "folder.badge.plus", action: #selector(createFolder), tooltip: "新規フォルダー（⌘⇧N）")
        let cut = button("", icon: "scissors", action: #selector(cutFiles), tooltip: "切り取り（⌘X）")
        let copy = button("", icon: "doc.on.doc", action: #selector(copyFiles), tooltip: "コピー（⌘C）")
        pasteButton = button("", icon: "doc.on.clipboard", action: #selector(pasteFiles), tooltip: "貼り付け（⌘V）")
        let rename = button("", icon: "pencil", action: #selector(renameFile), tooltip: "名前を変更（F2）")
        let trash = button("", icon: "trash", action: #selector(trashFiles), tooltip: "ごみ箱に移動（⌘⌫）")
        hiddenButton = button("隠しファイル", icon: "eye.slash", action: #selector(toggleHidden), tooltip: "隠しファイルを表示（⌘⇧.）")
        hiddenButton.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        let toolbar = stack([newFolder, divider(), cut, copy, pasteButton, rename, trash, spacer, hiddenButton], spacing: 7)
        let toolbarBox = box(NSColor(calibratedWhite: 0.985, alpha: 1))
        toolbarBox.heightAnchor.constraint(equalToConstant: 47).isActive = true
        constrain(toolbar, in: toolbarBox, top: 8, left: 23, bottom: 8, right: 21)
        column.addArrangedSubview(toolbarBox)

        table.dataSource = self; table.delegate = self
        table.rowHeight = 37
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.style = .fullWidth
        table.backgroundColor = .white
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(openSelection)
        table.focusRingType = .none
        table.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        for (id, title, width) in [("name", "名前", 340.0), ("modified", "更新日時", 162.0), ("kind", "種類", 125.0), ("size", "サイズ", 85.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = width; c.minWidth = id == "name" ? 180 : 70
            c.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let menu = NSMenu()
        for (title, action) in [("開く", #selector(openSelection)), ("新しいタブで開く", #selector(openInTab)), ("切り取り", #selector(cutFiles)), ("コピー", #selector(copyFiles)), ("貼り付け", #selector(pasteFiles)), ("名前を変更…", #selector(renameFile)), ("ごみ箱に移動", #selector(trashFiles)), ("新規フォルダー…", #selector(createFolder)), ("情報を見る", #selector(showInfo)), ("Finderで表示", #selector(revealInFinder))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let tableBox = NSView()
        constrain(scroll, in: tableBox, left: 14, right: 14)
        let emptyIcon = NSImageView(image: symbol("folder", size: 42)!)
        emptyIcon.contentTintColor = Theme.muted
        emptyView.orientation = .vertical; emptyView.alignment = .centerX; emptyView.spacing = 12
        [emptyIcon, emptyTitle, emptySubtitle].forEach { emptyView.addArrangedSubview($0) }
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        tableBox.addSubview(emptyView)
        NSLayoutConstraint.activate([emptyView.centerXAnchor.constraint(equalTo: tableBox.centerXAnchor), emptyView.centerYAnchor.constraint(equalTo: tableBox.centerYAnchor), emptyView.widthAnchor.constraint(lessThanOrEqualTo: tableBox.widthAnchor, constant: -40)])
        column.addArrangedSubview(tableBox)
        tableBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let footer = box(NSColor(calibratedWhite: 0.98, alpha: 1))
        footer.heightAnchor.constraint(equalToConstant: 36).isActive = true
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let footerRow = stack([statusLabel, NSView(), progress, selectionLabel], spacing: 10)
        constrain(footerRow, in: footer, top: 8, left: 26, bottom: 8, right: 25)
        column.addArrangedSubview(footer)
    }

    func divider() -> NSView {
        let view = box(Theme.line)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }

    var isWindowMaximized: Bool {
        guard let window, let visible = window.screen?.visibleFrame else { return false }
        let frame = window.frame
        return abs(frame.minX - visible.minX) < 1 && abs(frame.minY - visible.minY) < 1
            && abs(frame.width - visible.width) < 1 && abs(frame.height - visible.height) < 1
    }

    @objc func minimizeWindow() { window?.performMiniaturize(nil) }
    @objc func closeWindow() { window?.performClose(nil) }
    @objc func toggleMaximizeWindow() {
        guard let window, let screen = window.screen else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else if isWindowMaximized {
            let visible = screen.visibleFrame
            let fallbackSize = NSSize(width: min(1220, visible.width * 0.85), height: min(780, visible.height * 0.85))
            let fallback = NSRect(x: visible.midX - fallbackSize.width / 2, y: visible.midY - fallbackSize.height / 2, width: fallbackSize.width, height: fallbackSize.height)
            let restored = window.constrainFrameRect(frameBeforeMaximizing ?? fallback, to: screen)
            window.setFrame(restored, display: true)
            frameBeforeMaximizing = nil
        } else {
            frameBeforeMaximizing = window.frame
            // Windows-style maximize uses the usable desktop, leaving the menu bar
            // and Dock available rather than entering macOS full-screen mode.
            window.setFrame(screen.visibleFrame, display: true)
        }
        updateWindowControls()
    }

    func updateWindowControls() {
        guard let maximizeButton else { return }
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        let restore = fullScreen || isWindowMaximized
        let title = fullScreen ? "フルスクリーンを解除" : (restore ? "ウィンドウを元のサイズに戻す" : "ウィンドウを最大化")
        maximizeButton.image = symbol(restore ? "rectangle.on.rectangle" : "rectangle", size: 13)
        maximizeButton.toolTip = title
        maximizeButton.setAccessibilityLabel(title)
    }
    func windowDidResize(_ notification: Notification) { updateWindowControls() }
    func windowDidMove(_ notification: Notification) { updateWindowControls() }
    func windowDidChangeScreen(_ notification: Notification) { updateWindowControls() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateWindowControls() }
    func windowDidExitFullScreen(_ notification: Notification) { updateWindowControls() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { NSSound.beep(); return false }
        saveSession()
        return true
    }

    func buildSidebar() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let quick = FolderNode("クイックアクセス", heading: true, children: [
            FolderNode("ホーム", url: home, icon: "house"),
            FolderNode("デスクトップ", url: home.appendingPathComponent("Desktop"), icon: "desktopcomputer"),
            FolderNode("ダウンロード", url: home.appendingPathComponent("Downloads"), icon: "arrow.down.circle"),
            FolderNode("書類", url: home.appendingPathComponent("Documents"), icon: "doc.text"),
            FolderNode("ピクチャ", url: home.appendingPathComponent("Pictures"), icon: "photo"),
            FolderNode("アプリケーション", url: URL(fileURLWithPath: "/Applications"), icon: "square.grid.2x2")
        ])
        // Quick access remains flat; the section below is the expandable directory tree.
        quick.children?.forEach { $0.children = [] }
        let folders = FolderNode("フォルダーツリー", heading: true, children: [FolderNode(home.lastPathComponent, url: home, icon: "person.crop.square"), FolderNode("Macintosh HD", url: URL(fileURLWithPath: "/"), icon: "internaldrive")])
        let volumes = FolderNode("場所", heading: true, children: [FolderNode("ボリューム", url: URL(fileURLWithPath: "/Volumes"), icon: "externaldrive")])
        roots = [quick, folders, volumes]
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }
        if let homeNode = folders.children?.first { outline.expandItem(homeNode) }
    }

    func displayName(_ url: URL) -> String {
        if url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL { return "ホーム" }
        if url.path == "/" { return "Macintosh HD" }
        return url.lastPathComponent
    }

    func renderTabs() {
        tabStack.arrangedSubviews.forEach { tabStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let selected = index == activeIndex
            let holder = box(selected ? .white : .clear, radius: 7)
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.widthAnchor.constraint(equalToConstant: 176).isActive = true
            holder.heightAnchor.constraint(equalToConstant: 33).isActive = true
            if selected { holder.layer?.borderWidth = 1; holder.layer?.borderColor = Theme.line.cgColor }
            let select = button(displayName(tab.history.current), icon: "folder", action: #selector(selectTab(_:)))
            select.tag = index
            select.contentTintColor = selected ? Theme.accent : Theme.muted
            select.toolTip = tab.history.current.path
            let close = button("", icon: "xmark", action: #selector(closeTabButton(_:)), tooltip: "タブを閉じる")
            close.tag = index
            let row = stack([select, close], spacing: 0)
            constrain(row, in: holder, top: 1, left: 5, bottom: 1, right: 1)
            select.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tabStack.addArrangedSubview(holder)
        }
        saveSession()
    }

    func saveSession() {
        UserDefaults.standard.set(tabs.map { $0.history.current.path }, forKey: "tabPaths")
        UserDefaults.standard.set(activeIndex, forKey: "activeTab")
    }

    func navigate(_ url: URL) {
        guard !busy else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            showError("フォルダーを開けません", "フォルダーが見つからないか、アクセスが許可されていません。\n\(url.path)")
            pathField.stringValue = directory.path
            return
        }
        rememberSelection()
        currentTab.history.visit(url)
        currentTab.selection = []
        currentTab.query = ""
        refresh()
    }

    func refresh() {
        errorMessage = nil
        do { entries = try FileService.list(directory, showHidden: showHidden) }
        catch { entries = []; errorMessage = error.localizedDescription }
        titleLabel.stringValue = displayName(directory)
        subtitleLabel.stringValue = directory.path
        pathField.stringValue = directory.path
        searchField.stringValue = currentTab.query
        window?.title = "\(displayName(directory)) — ExpMos"
        window?.representedURL = directory
        backButton.isEnabled = currentTab.history.canGoBack
        forwardButton.isEnabled = currentTab.history.canGoForward
        upButton.isEnabled = directory.path != "/"
        hiddenButton.contentTintColor = showHidden ? Theme.accent : Theme.muted
        hiddenButton.image = symbol(showHidden ? "eye" : "eye.slash")
        applyFilter()
        renderTabs()
        watchDirectory()
        updateClipboard()
    }

    func applyFilter() {
        updatingTable = true
        defer { updatingTable = false }
        let query = currentTab.query
        visibleEntries = entries.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        let descriptor = table.sortDescriptors.first
        let ascending = descriptor?.ascending ?? true
        visibleEntries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var order: ComparisonResult
            switch descriptor?.key {
            case "size": order = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case "modified": order = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case "kind": order = a.kind.localizedStandardCompare(b.kind)
            default: order = a.name.localizedStandardCompare(b.name)
            }
            if order == .orderedSame { order = a.name.localizedStandardCompare(b.name) }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        let selection = currentTab.selection
        table.reloadData()
        let indexes = IndexSet(visibleEntries.enumerated().compactMap { selection.contains($0.element.url) ? $0.offset : nil })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        emptyView.isHidden = !visibleEntries.isEmpty
        if let errorMessage {
            emptyTitle.stringValue = "フォルダーを読み込めません"
            emptySubtitle.stringValue = errorMessage
            emptySubtitle.toolTip = errorMessage
        } else {
            emptyTitle.stringValue = query.isEmpty ? "このフォルダーは空です" : "一致する項目はありません"
            emptySubtitle.stringValue = query.isEmpty ? "新規フォルダーを作成するか、項目を貼り付けてください。" : "別の名前で検索してください。このフォルダーの直下を検索しています。"
        }
        updateStatus()
    }

    func rememberSelection() { if !updatingTable { currentTab.selection = Set(selectedURLs) } }
    var selectedEntries: [FileEntry] { table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil } }
    var selectedURLs: [URL] { selectedEntries.map(\.url) }

    func updateStatus() {
        let folders = visibleEntries.filter(\.isDirectory).count
        statusLabel.stringValue = errorMessage == nil ? "\(visibleEntries.count) 項目  ·  \(folders) フォルダー / \(visibleEntries.count - folders) ファイル" + (showHidden ? "  ·  隠しファイルを表示" : "") : "読み込みエラー  ·  ⌘R で再試行"
        let selected = selectedEntries
        let bytes = selected.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        selectionLabel.stringValue = selected.isEmpty ? "Enter で開く  ·  F2 で名前を変更" : "\(selected.count) 項目を選択" + (bytes > 0 ? "  ·  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "")
    }

    func watchDirectory() {
        watcher?.cancel(); watcher = nil
        let fd = Darwin.open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        let tabID = currentTab.id
        source.setEventHandler { [weak self] in
            guard let self, self.currentTab.id == tabID, !self.busy else { return }
            self.rememberSelection()
            self.refresh()
            self.reloadTree()
        }
        source.setCancelHandler { Darwin.close(fd) }
        watcher = source
        source.resume()
    }

    func reloadTree() {
        var expanded = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FolderNode, let url = node.url, outline.isItemExpanded(node) { expanded.insert(url.path) }
        }
        roots.dropFirst().forEach { $0.invalidate() }
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }
        func restore(_ node: FolderNode) {
            guard node.heading || node.url.map({ expanded.contains($0.path) }) == true else { return }
            outline.expandItem(node)
            node.load(hidden: showHidden).forEach(restore)
        }
        roots.dropFirst().forEach(restore)
    }

    @objc func pathEntered() {
        let text = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (text as NSString).expandingTildeInPath
        let url: URL
        if text.hasPrefix("file://"), let parsed = URL(string: text), parsed.isFileURL { url = parsed }
        else if expanded.hasPrefix("/") { url = URL(fileURLWithPath: expanded, isDirectory: true) }
        else { url = directory.appendingPathComponent(expanded, isDirectory: true) }
        navigate(url.standardizedFileURL)
        window?.makeFirstResponder(table)
    }
    @objc func focusPath() { window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    @objc func focusSearch() { window?.makeFirstResponder(searchField); searchField.selectText(nil) }
    @objc func reloadFolder() { guard !busy else { return }; rememberSelection(); refresh(); reloadTree() }
    @objc func goBack() { guard !busy else { return }; rememberSelection(); currentTab.history.back(); currentTab.selection = []; refresh() }
    @objc func goForward() { guard !busy else { return }; rememberSelection(); currentTab.history.forward(); currentTab.selection = []; refresh() }
    @objc func goUp() { navigate(directory.deletingLastPathComponent()) }
    @objc func goHome() { navigate(FileManager.default.homeDirectoryForCurrentUser) }
    @objc func toggleHidden() {
        showHidden.toggle(); UserDefaults.standard.set(showHidden, forKey: "showHidden")
        rememberSelection(); refresh(); reloadTree()
    }
    @objc func newTab() {
        guard !busy else { return }
        rememberSelection(); tabs.append(FolderTab(directory)); activeIndex = tabs.count - 1; refresh()
    }
    @objc func selectTab(_ sender: NSButton) { activateTab(sender.tag) }
    func activateTab(_ index: Int) {
        guard !busy, tabs.indices.contains(index) else { return }
        rememberSelection(); activeIndex = index; refresh()
    }
    @objc func nextTab() { activateTab((activeIndex + 1) % tabs.count) }
    @objc func previousTab() { activateTab((activeIndex + tabs.count - 1) % tabs.count) }
    @objc func closeTabButton(_ sender: NSButton) { closeTab(at: sender.tag) }
    @objc func closeCurrentTab() { closeTab(at: activeIndex) }
    func closeTab(at index: Int) {
        guard !busy, tabs.indices.contains(index) else { return }
        if tabs.count == 1 { window?.close(); return }
        rememberSelection()
        tabs.remove(at: index)
        if index < activeIndex { activeIndex -= 1 }
        activeIndex = min(activeIndex, tabs.count - 1)
        refresh()
    }
    @objc func openSelection() {
        guard !busy else { return }
        let selected = selectedEntries
        if selected.count == 1, let entry = selected.first, entry.isDirectory, !NSWorkspace.shared.isFilePackage(atPath: entry.url.path) {
            navigate(entry.url)
        } else { selected.forEach { NSWorkspace.shared.open($0.url) } }
    }
    @objc func openInTab() {
        guard !busy else { return }
        let folders = selectedEntries.filter { $0.isDirectory && !NSWorkspace.shared.isFilePackage(atPath: $0.url.path) }
        guard !folders.isEmpty else { return }
        rememberSelection(); tabs += folders.map { FolderTab($0.url) }; activeIndex = tabs.count - 1; refresh()
    }
    @objc func sidebarClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FolderNode, let url = node.url else { return }
        navigate(url)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        rememberSelection(); currentTab.query = searchField.stringValue; applyFilter()
    }

    func writeClipboard(cut: Bool) {
        let urls = selectedURLs
        guard !urls.isEmpty, !busy else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.writeObjects(urls as [NSURL]) else {
            cutURLs = []; cutChangeCount = -1
            ownedClipboardURLs = []; ownedClipboardChangeCount = nil
            updateClipboard()
            showError("コピーできません", "クリップボードにファイルを保存できませんでした。")
            return
        }
        ownedClipboardURLs = urls; ownedClipboardChangeCount = pb.changeCount
        cutURLs = cut ? urls : []; cutChangeCount = cut ? pb.changeCount : -1
        reloadTablePreservingSelection(); updateClipboard()
        selectionLabel.stringValue = "\(urls.count) 項目を\(cut ? "切り取り" : "コピー")しました。移動先で ⌘V"
    }
    @objc func copyFiles() { writeClipboard(cut: false) }
    @objc func cutFiles() { writeClipboard(cut: true) }
    func clipboardURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    func updateClipboard() {
        let changeCount = NSPasteboard.general.changeCount
        if !cutURLs.isEmpty && changeCount != cutChangeCount { cutURLs = []; reloadTablePreservingSelection() }
        if let ownedClipboardChangeCount, changeCount != ownedClipboardChangeCount {
            ownedClipboardURLs = []; self.ownedClipboardChangeCount = nil
        }
        pasteButton.isEnabled = !busy && !clipboardURLs().isEmpty
    }
    func reloadTablePreservingSelection() {
        let indexes = table.selectedRowIndexes
        updatingTable = true
        table.reloadData()
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        updatingTable = false
    }
    @objc func pasteFiles() {
        guard !busy else { return }
        let pb = NSPasteboard.general
        let changeCountBefore = pb.changeCount
        let clipboardItems = clipboardURLs()
        let changeCountAfter = pb.changeCount
        guard changeCountBefore == changeCountAfter else {
            showError("貼り付けをやり直してください", "クリップボードの内容が読み取り中に変わりました。")
            return
        }
        guard !clipboardItems.isEmpty else { return }
        let appOwned = PasteboardSecurity.isAppOwned(clipboardItems, changeCountBefore: changeCountBefore,
            changeCountAfter: changeCountAfter, ownedURLs: ownedClipboardURLs,
            ownedChangeCount: ownedClipboardChangeCount)
        let urls = FileService.topLevelURLs(clipboardItems)
        let move = appOwned && !cutURLs.isEmpty && cutChangeCount == changeCountAfter
        let target = directory
        if !appOwned {
            let prepared: PreparedExternalPaste
            do { prepared = try PreparedExternalPaste(urls, to: target) }
            catch { showError("貼り付けできません", error.localizedDescription); return }
            guard prepared.sourceCount > 0 else {
                showError("貼り付けできません", prepared.preparationFailures.joined(separator: "\n"))
                return
            }
            setBusy(true, message: "貼り付けを確認しています…")
            confirmExternalPaste(prepared) { [weak self] approved in
                guard let self else { return }
                if approved { self.startExternalPaste(prepared) }
                else { self.setBusy(false) }
            }
            return
        }
        startPaste(urls, to: target, move: move)
    }
    func confirmExternalPaste(_ prepared: PreparedExternalPaste, completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = "外部アプリからファイルをコピー"
        alert.informativeText = "コピー元とコピー先を確認してください。フォルダーは中身もコピーされます。"
        alert.addButton(withTitle: "コピー")
        alert.addButton(withTitle: "キャンセル")
        let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        details.isEditable = false
        details.isSelectable = true
        details.isRichText = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.string = "コピー元（\(prepared.sourceCount)件）:\n" +
            prepared.sourceDescriptions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") +
            "\n\nコピー先:\n\(String(reflecting: prepared.destinationURL.path))" +
            (prepared.preparationFailures.isEmpty ? "" : "\n\n処理できない項目:\n" + prepared.preparationFailures.joined(separator: "\n"))
        details.isVerticallyResizable = true
        details.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
    }
    func startExternalPaste(_ prepared: PreparedExternalPaste) {
        setBusy(true, message: "項目をコピーしています…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = prepared.transfer()
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                self.currentTab.selection = Set(result.completed.map { self.directory.appendingPathComponent($0.lastPathComponent) })
                self.refresh(); self.reloadTree()
                if !result.failures.isEmpty { self.showError("一部の項目を処理できませんでした", result.failures.joined(separator: "\n")) }
                else { self.selectionLabel.stringValue = "\(result.completed.count) 項目をコピーしました" }
            }
        }
    }
    func startPaste(_ urls: [URL], to target: URL, move: Bool) {
        setBusy(true, message: move ? "項目を移動しています…" : "項目をコピーしています…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FileService.transfer(urls, to: target, move: move)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                if move && NSPasteboard.general.changeCount == self.cutChangeCount {
                    // Keep failed sources on the cut clipboard so the user can retry.
                    let remaining = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    let wroteRemaining = remaining.isEmpty || pb.writeObjects(remaining as [NSURL])
                    self.cutURLs = wroteRemaining ? remaining : []
                    self.cutChangeCount = wroteRemaining && !remaining.isEmpty ? pb.changeCount : -1
                    self.ownedClipboardURLs = wroteRemaining ? remaining : []
                    self.ownedClipboardChangeCount = wroteRemaining && !remaining.isEmpty ? pb.changeCount : nil
                }
                self.currentTab.selection = Set(result.completed.map { self.directory.appendingPathComponent($0.lastPathComponent) })
                self.refresh(); self.reloadTree()
                if !result.failures.isEmpty { self.showError("一部の項目を処理できませんでした", result.failures.joined(separator: "\n")) }
                else { self.selectionLabel.stringValue = "\(result.completed.count) 項目を\(move ? "移動" : "コピー")しました" }
            }
        }
    }
    func setBusy(_ value: Bool, message: String = "") {
        busy = value
        if value { progress.startAnimation(nil); selectionLabel.stringValue = message }
        else { progress.stopAnimation(nil) }
        pathField.isEnabled = !value
        searchField.isEnabled = !value
        outline.isEnabled = !value
        closeWindowButton.isEnabled = !value
        updateClipboard()
    }

    func askName(title: String, initial: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "キャンセル")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        input.stringValue = initial; input.font = .systemFont(ofSize: 13)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(input.stringValue) }
        }
        input.selectText(nil)
    }
    @objc func createFolder() {
        guard !busy else { return }
        let target = directory
        askName(title: "新規フォルダー", initial: FileService.availableURL(in: target, name: "新しいフォルダー").lastPathComponent) { [weak self] name in
            guard let self else { return }
            do { let url = try FileService.createFolder(in: target, name: name); self.currentTab.selection = [url]; self.refresh(); self.reloadTree() }
            catch { self.showError("フォルダーを作成できません", error.localizedDescription) }
        }
    }
    @objc func renameFile() {
        guard !busy, selectedURLs.count == 1, let source = selectedURLs.first else { return }
        askName(title: "名前を変更", initial: source.lastPathComponent) { [weak self] name in
            guard let self else { return }
            do {
                let target = try FileService.rename(source, to: name)
                self.rebaseTabs(from: source, to: target)
                self.currentTab.selection = [target]; self.refresh(); self.reloadTree()
            } catch { self.showError("名前を変更できません", error.localizedDescription) }
        }
    }
    func rebaseTabs(from source: URL, to target: URL) {
        for tab in tabs {
            let path = tab.history.current.path
            if path == source.path || path.hasPrefix(source.path + "/") {
                let suffix = String(path.dropFirst(source.path.count))
                tab.history = NavigationHistory(URL(fileURLWithPath: target.path + suffix))
            }
        }
    }
    @objc func trashFiles() {
        guard !busy else { return }
        let urls = FileService.topLevelURLs(selectedURLs)
        guard !urls.isEmpty else { return }
        setBusy(true, message: "ごみ箱に移動しています…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            for url in urls {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            let errors = failures
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false); self.currentTab.selection = []; self.refresh(); self.reloadTree()
                if !errors.isEmpty { self.showError("ごみ箱に移動できない項目があります", errors.joined(separator: "\n")) }
                else { self.selectionLabel.stringValue = "\(urls.count) 項目をごみ箱に移動しました" }
            }
        }
    }
    @objc func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs.isEmpty ? [directory] : selectedURLs) }
    @objc func showInfo() {
        guard let entry = selectedEntries.first else { return }
        let date = entry.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "—"
        let alert = NSAlert()
        alert.messageText = entry.name
        alert.informativeText = "種類: \(entry.kind)\nサイズ: \(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))\n更新日時: \(date)\n場所: \(entry.url.path)"
        alert.icon = NSWorkspace.shared.icon(forFile: entry.url.path)
        if let window { alert.beginSheetModal(for: window) }
    }
    func showError(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = detail
        if let window { alert.beginSheetModal(for: window) }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if busy { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option) {
            if event.keyCode == 123 { goBack(); return true }
            if event.keyCode == 124 { goForward(); return true }
            if event.keyCode == 126 { goUp(); return true }
        }
        if flags.contains(.command), event.keyCode == 126 { goUp(); return true }
        if flags.contains(.command), event.keyCode == 125 { openSelection(); return true }
        if flags.contains(.command), event.keyCode == 51 { trashFiles(); return true }
        if flags.isDisjoint(with: [.command, .control, .option]) {
            if event.keyCode == 36 || event.keyCode == 76 { openSelection(); return true }
            if event.keyCode == 120 { renameFile(); return true }
            if event.keyCode == 96 { reloadFolder(); return true }
            if event.keyCode == 53 { cutURLs = []; cutChangeCount = -1; reloadTablePreservingSelection(); return true }
        }
        return false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if busy { return false }
        switch menuItem.action {
        case #selector(copyFiles), #selector(cutFiles), #selector(trashFiles), #selector(openSelection), #selector(showInfo): return !selectedURLs.isEmpty
        case #selector(renameFile): return selectedURLs.count == 1
        case #selector(pasteFiles): return !clipboardURLs().isEmpty
        case #selector(openInTab): return selectedEntries.contains { $0.isDirectory }
        case #selector(goBack): return currentTab.history.canGoBack
        case #selector(goForward): return currentTab.history.canGoForward
        case #selector(toggleHidden): menuItem.state = showHidden ? .on : .off; return true
        default: return true
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { guard !updatingTable else { return }; rememberSelection(); updateStatus() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { rememberSelection(); applyFilter() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let entry = visibleEntries[row]
        let cell = NSTableCellView()
        let text = label("", size: 12, color: Theme.ink)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text); cell.textField = text
        if tableColumn?.identifier.rawValue == "name" {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: entry.url.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon); cell.imageView = icon
            text.stringValue = entry.name
            text.font = .systemFont(ofSize: 13, weight: entry.isDirectory ? .medium : .regular)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10)
            ])
            if cutURLs.contains(entry.url) { cell.alphaValue = 0.4 }
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            text.textColor = Theme.muted
            switch tableColumn?.identifier.rawValue {
            case "modified":
                text.stringValue = entry.modified.map { Self.dateFormatter.string(from: $0) } ?? "—"
            case "kind": text.stringValue = entry.isDirectory && !NSWorkspace.shared.isFilePackage(atPath: entry.url.path) ? "フォルダー" : entry.kind
            case "size":
                text.stringValue = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
                text.alignment = .right
                text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            default: break
            }
        }
        NSLayoutConstraint.activate([text.centerYAnchor.constraint(equalTo: cell.centerYAnchor), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)])
        cell.toolTip = entry.url.path
        return cell
    }
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd  HH:mm"; return formatter
    }()

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderNode)?.load(hidden: showHidden).count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FolderNode { return node.load(hidden: showHidden)[index] }
        return roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        return node.heading || node.children == nil || !(node.children?.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? FolderNode)?.heading ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? FolderNode)?.heading ?? false) }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as? FolderNode)?.heading == true ? 34 : 31 }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        if node.heading { return label(node.title, size: 10, weight: .semibold, color: Theme.muted) }
        let icon = NSImageView(image: symbol(node.icon, size: 15)!)
        icon.contentTintColor = Theme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let text = label(node.title, size: 12)
        let row = stack([icon, text], spacing: 9)
        row.toolTip = node.url?.path
        return row
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ExplorerController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = ExplorerController()
        makeMenu()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeFirstResponder(controller.table)
        if let path = ProcessInfo.processInfo.environment["EXPMOS_START_PATH"] { controller.navigate(URL(fileURLWithPath: path, isDirectory: true)) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.busy { NSSound.beep(); return .terminateCancel }
        controller.saveSession(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showWindow(nil); return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard controller != nil else { return }
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            controller.navigate(isDir ? url : url.deletingLastPathComponent())
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func makeMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ExpMosについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ExpMosを隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ExpMosを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        func addMenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let menu = NSMenu(title: title)
            for (name, action, key, flags) in items {
                let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = flags
                item.target = controller
                menu.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); parent.submenu = menu; main.addItem(parent)
        }
        addMenu("ファイル", [
            ("新しいタブ", #selector(ExplorerController.newTab), "t", .command),
            ("タブを閉じる", #selector(ExplorerController.closeCurrentTab), "w", .command),
            ("新規フォルダー…", #selector(ExplorerController.createFolder), "N", [.command, .shift]),
            ("開く", #selector(ExplorerController.openSelection), "o", .command),
            ("新しいタブで開く", #selector(ExplorerController.openInTab), "o", [.command, .option]),
            ("情報を見る", #selector(ExplorerController.showInfo), "i", .command),
            ("Finderで表示", #selector(ExplorerController.revealInFinder), "r", [.command, .shift])
        ])
        // Nil targets let the text field handle editing shortcuts while it is focused.
        let edit = NSMenu(title: "編集")
        for (name, action, key) in [("切り取り", #selector(NSText.cut(_:)), "x"), ("コピー", #selector(NSText.copy(_:)), "c"), ("貼り付け", #selector(NSText.paste(_:)), "v"), ("すべて選択", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        edit.addItem(.separator())
        let rename = NSMenuItem(title: "名前を変更…", action: #selector(ExplorerController.renameFile), keyEquivalent: ""); rename.target = controller; edit.addItem(rename)
        let trash = NSMenuItem(title: "ごみ箱に移動", action: #selector(ExplorerController.trashFiles), keyEquivalent: "\u{8}"); trash.target = controller; edit.addItem(trash)
        let editItem = NSMenuItem(title: "編集", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        addMenu("表示", [
            ("更新", #selector(ExplorerController.reloadFolder), "r", .command),
            ("隠しファイルを表示", #selector(ExplorerController.toggleHidden), ".", [.command, .shift]),
            ("このフォルダー内を検索", #selector(ExplorerController.focusSearch), "f", .command),
            ("次のタブ", #selector(ExplorerController.nextTab), "\t", [.control]),
            ("前のタブ", #selector(ExplorerController.previousTab), "\t", [.control, .shift])
        ])
        addMenu("移動", [
            ("戻る", #selector(ExplorerController.goBack), "[", .command),
            ("進む", #selector(ExplorerController.goForward), "]", .command),
            ("親フォルダーへ", #selector(ExplorerController.goUp), "\u{f700}", .command),
            ("ホーム", #selector(ExplorerController.goHome), "h", [.command, .shift]),
            ("パスを入力", #selector(ExplorerController.focusPath), "l", .command)
        ])
        addMenu("ウィンドウ", [
            ("最小化", #selector(ExplorerController.minimizeWindow), "m", .command),
            ("最大化／元のサイズに戻す", #selector(ExplorerController.toggleMaximizeWindow), "", []),
            ("ウィンドウを閉じる", #selector(ExplorerController.closeWindow), "w", [.command, .shift])
        ])
        NSApp.mainMenu = main
    }
}

extension ExplorerTable {
    @objc func copy(_ sender: Any?) { (delegate as? ExplorerController)?.copyFiles() }
    @objc func cut(_ sender: Any?) { (delegate as? ExplorerController)?.cutFiles() }
    @objc func paste(_ sender: Any?) { (delegate as? ExplorerController)?.pasteFiles() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
