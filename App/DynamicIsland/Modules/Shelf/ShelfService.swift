import AppKit
import IslandCore
import Observation
import UniformTypeIdentifiers

/// Files parked on the island. Files stay where they are and are referenced
/// by bookmark (so moves are followed); text, links and images dropped in
/// are saved as files in Application Support. Survives relaunches.
@Observable
final class ShelfService: ActivityProvider {
    let kind = ActivityKind.shelf
    private(set) var items: [ShelfItemInfo] = []
    /// Items the user has clicked to select; actions apply to these, or to all.
    var selection: Set<UUID> = []

    @ObservationIgnored private var bookmarks: [UUID: Data] = [:]
    @ObservationIgnored private var icons: [UUID: NSImage] = [:]
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let storeURL: URL

    private struct Stored: Codable {
        var item: ShelfItemInfo
        var bookmark: Data?
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicIsland", isDirectory: true)
        folder = support.appendingPathComponent("Shelf", isDirectory: true)
        storeURL = support.appendingPathComponent("shelf.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    var activities: [Activity] {
        guard let first = items.first else { return [] }
        return [Activity(id: "shelf", kind: .shelf, payload: .shelf(items), relevance: 0.2, startedAt: first.addedAt)]
    }

    var selectedOrAll: [ShelfItemInfo] {
        let chosen = items.filter { selection.contains($0.id) }
        return chosen.isEmpty ? items : chosen
    }

    // MARK: adding

    func add(urls: [URL]) {
        var added = 0
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !items.contains(where: { $0.path == path }) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .isPackageKey])
            let kind: ShelfItemKind = (values?.isDirectory == true && values?.isPackage != true) ? .folder
                : (values?.contentType?.conforms(to: .image) == true ? .image : .file)
            let item = ShelfItemInfo(name: FileManager.default.displayName(atPath: path), kind: kind, path: path)
            items.append(item)
            bookmarks[item.id] = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            added += 1
        }
        if added > 0 { save(); Log.info("shelf: added \(added), now \(items.count)") }
    }

    func add(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()), !trimmed.contains(" ") {
            // Links become .webloc files, which Finder and browsers open.
            let name = (url.host ?? "Link") + ".webloc"
            let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
            if let file = write(data, name: name) { addSaved(file, kind: .link, name: url.host ?? "Link") }
        } else {
            let title = String(trimmed.prefix(40)).replacingOccurrences(of: "\n", with: " ")
            if let file = write(Data(trimmed.utf8), name: "Text \(Self.stamp()).txt") { addSaved(file, kind: .text, name: title) }
        }
    }

    func add(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        if let file = write(png, name: "Image \(Self.stamp()).png") { addSaved(file, kind: .image, name: "Image") }
    }

    /// Accepts whatever was dropped on the island.
    func accept(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    Task { @MainActor in self?.add(urls: [url]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { [weak self] image, _ in
                    guard let image = image as? NSImage else { return }
                    let box = SendableBox(image)
                    Task { @MainActor in self?.add(image: box.value) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                handled = true
                _ = p.loadObject(ofClass: String.self) { [weak self] text, _ in
                    guard let text else { return }
                    Task { @MainActor in self?.add(text: text) }
                }
            }
        }
        return handled
    }

    // MARK: using

    func url(for item: ShelfItemInfo) -> URL {
        if let data = bookmarks[item.id] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale || url.path != item.path { refresh(item, to: url) }
                return url
            }
        }
        return URL(fileURLWithPath: item.path)
    }

    func exists(_ item: ShelfItemInfo) -> Bool {
        FileManager.default.fileExists(atPath: url(for: item).path)
    }

    /// The item's drive isn't connected: it stays, dimmed, until the drive is back.
    func isOnMissingDrive(_ item: ShelfItemInfo) -> Bool {
        guard let volume = item.volume else { return false }
        return !FileManager.default.fileExists(atPath: volume)
    }

    func icon(for item: ShelfItemInfo) -> NSImage {
        if let cached = icons[item.id] { return cached }
        // Not kept while the drive is away, so the real icon shows once it's back.
        if isOnMissingDrive(item) { return NSWorkspace.shared.icon(for: .data) }
        let u = url(for: item)
        var image = NSWorkspace.shared.icon(forFile: u.path)
        // A picture shows itself, at thumbnail size (the shelf's tiles are small).
        if item.kind == .image, let thumb = Thumbnail.image(at: u, maxPixels: 256) { image = thumb }
        icons[item.id] = image
        return image
    }

    func open(_ item: ShelfItemInfo) { NSWorkspace.shared.open(url(for: item)) }

    func reveal(_ items: [ShelfItemInfo]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(url(for:)))
    }

    func airDrop(_ items: [ShelfItemInfo]) {
        let urls = items.map(url(for:))
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            Log.error("AirDrop unavailable for \(items.count) items")
            return
        }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// The system Share menu for the given items (Mail, Messages, Notes…).
    func shareMenu(for items: [ShelfItemInfo]) -> NSMenu {
        let picker = NSSharingServicePicker(items: items.map(url(for:)))
        let menu = NSMenu()
        let share = picker.standardShareMenuItem
        menu.addItem(share)
        return menu
    }

    func remove(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) {
            // Only delete files the shelf created itself; never the user's own files.
            if item.path.hasPrefix(folder.path) { try? FileManager.default.removeItem(atPath: item.path) }
            bookmarks[item.id] = nil
            icons[item.id] = nil
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func clear() { remove(Set(items.map(\.id))) }

    func toggleSelection(_ item: ShelfItemInfo) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    // MARK: storage

    private func addSaved(_ file: URL, kind: ShelfItemKind, name: String) {
        let item = ShelfItemInfo(name: name, kind: kind, path: file.path)
        items.append(item)
        bookmarks[item.id] = try? file.bookmarkData()
        save()
    }

    private func write(_ data: Data?, name: String) -> URL? {
        guard let data else { return nil }
        let url = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        do { try data.write(to: url); return url } catch { Log.error("shelf write failed: \(error)"); return nil }
    }

    private func refresh(_ item: ShelfItemInfo, to url: URL) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].path = url.path
        bookmarks[item.id] = try? url.bookmarkData()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        items = stored.map(\.item)
        for s in stored { bookmarks[s.item.id] = s.bookmark }
        // Drop items whose files are gone for good; ones on a drive that isn't
        // connected right now wait for it.
        let missing = Set(items.filter { !exists($0) && !isOnMissingDrive($0) }.map(\.id))
        if !missing.isEmpty { items.removeAll { missing.contains($0.id) }; save() }
    }

    private func save() {
        let stored = items.map { Stored(item: $0, bookmark: bookmarks[$0.id]) }
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: storeURL, options: .atomic) }
    }

    /// For file names: the same digits whatever the language, calendar or clock setting.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    private static func stamp() -> String {
        stampFormatter.string(from: Date())
    }
}

/// Moves a non-Sendable value across a concurrency hop the caller knows is safe.
nonisolated struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
