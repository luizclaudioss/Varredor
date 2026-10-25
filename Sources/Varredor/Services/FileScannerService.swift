import Foundation
import CoreServices
import AppKit

@MainActor
final class FileScannerService: ObservableObject {
    @Published var scannedItems: [ScannedItem] = []
    @Published var isScanning: Bool = false
    @Published var currentScanningPath: String = ""
    @Published var scannedCount: Int = 0
    @Published var locations: [ScanLocation] = []
    @Published var lastScanDate: Date? = nil
    @Published var errorMessage: String? = nil

    private var scanTask: Task<Void, Never>? = nil

    init() {
        setupDefaultLocations()
    }

    func setupDefaultLocations() {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        var defaultLocs: [ScanLocation] = [
            ScanLocation(
                id: "sys_apps",
                name: "Aplicativos (/Applications)",
                path: URL(fileURLWithPath: "/Applications", isDirectory: true),
                icon: "app.badge",
                isEnabled: true,
                isCustom: false
            )
        ]

        let userApps = home.appendingPathComponent("Applications", isDirectory: true)
        if fm.fileExists(atPath: userApps.path) {
            defaultLocs.append(
                ScanLocation(
                    id: "user_apps",
                    name: "Aplicativos do Usuário (~/Applications)",
                    path: userApps,
                    icon: "app.dashed",
                    isEnabled: true,
                    isCustom: false
                )
            )
        }

        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        if fm.fileExists(atPath: downloads.path) {
            defaultLocs.append(
                ScanLocation(
                    id: "downloads",
                    name: "Downloads",
                    path: downloads,
                    icon: "arrow.down.circle.fill",
                    isEnabled: true,
                    isCustom: false
                )
            )
        }

        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        if fm.fileExists(atPath: documents.path) {
            defaultLocs.append(
                ScanLocation(
                    id: "documents",
                    name: "Documentos",
                    path: documents,
                    icon: "doc.on.doc.fill",
                    isEnabled: true,
                    isCustom: false
                )
            )
        }

        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        if fm.fileExists(atPath: desktop.path) {
            defaultLocs.append(
                ScanLocation(
                    id: "desktop",
                    name: "Mesa (Desktop)",
                    path: desktop,
                    icon: "menubar.dock.rectangle",
                    isEnabled: true,
                    isCustom: false
                )
            )
        }

        self.locations = defaultLocs
    }

    func addCustomLocation(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !locations.contains(where: { $0.path.standardizedFileURL == standardized }) else {
            return
        }
        let loc = ScanLocation(
            id: UUID().uuidString,
            name: standardized.lastPathComponent,
            path: standardized,
            icon: "folder.fill.badge.plus",
            isEnabled: true,
            isCustom: true
        )
        locations.append(loc)
    }

    func removeCustomLocation(_ location: ScanLocation) {
        locations.removeAll { $0.id == location.id }
    }

    func toggleLocation(_ location: ScanLocation) {
        if let idx = locations.firstIndex(where: { $0.id == location.id }) {
            locations[idx].isEnabled.toggle()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentScanningPath = ""
    }

    func startScan(includeHidden: Bool) {
        scanTask?.cancel()
        let activeLocations = locations.filter { $0.isEnabled }
        guard !activeLocations.isEmpty else {
            errorMessage = "Selecione pelo menos uma pasta ou local para varrer."
            return
        }

        errorMessage = nil
        isScanning = true
        scannedCount = 0
        scannedItems = []
        currentScanningPath = "Iniciando varredura..."

        scanTask = Task {
            var collected: [ScannedItem] = []
            var seenPaths = Set<String>()

            for location in activeLocations {
                if Task.isCancelled { break }
                currentScanningPath = location.displayPath

                let items = await Self.scanDirectory(
                    at: location.path,
                    includeHidden: includeHidden
                ) { [weak self] count, currentPath in
                    Task { @MainActor in
                        guard let self = self, !Task.isCancelled else { return }
                        self.scannedCount += count
                        self.currentScanningPath = currentPath
                    }
                }

                for item in items {
                    let canonical = item.url.standardizedFileURL.path
                    if !seenPaths.contains(canonical) {
                        seenPaths.insert(canonical)
                        collected.append(item)
                    }
                }
            }

            if !Task.isCancelled {
                self.scannedItems = collected
                self.lastScanDate = Date()
                self.isScanning = false
                self.currentScanningPath = ""
            }
        }
    }

    func removeCompletedItems(_ items: [ScannedItem]) {
        guard !items.isEmpty else { return }
        let removedIDs = Set(items.map { $0.id })
        scannedItems.removeAll { removedIDs.contains($0.id) }
    }

    func revealInFinder(_ item: ScannedItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openItem(_ item: ScannedItem) {
        NSWorkspace.shared.open(item.url)
    }

    // MARK: - Background Worker

    nonisolated private static func scanDirectory(
        at rootURL: URL,
        includeHidden: Bool,
        progressCallback: @Sendable @escaping (Int, String) -> Void
    ) async -> [ScannedItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [
                .nameKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .isPackageKey,
                .isApplicationKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentAccessDateKey,
                .contentModificationDateKey,
                .creationDateKey,
                .addedToDirectoryDateKey
            ]

            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden {
                options.insert(.skipsHiddenFiles)
            }

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: options
            ) else {
                return []
            }

            let now = Date()
            let calendar = Calendar.current
            var results: [ScannedItem] = []
            var batchCounter = 0

            while let fileURL = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }

                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                    continue
                }

                // Ignore symlinks or Varredor itself
                if values.isSymbolicLink == true || fileURL.lastPathComponent == "Varredor.app" {
                    continue
                }

                let isApp = (values.isApplication == true) || (fileURL.pathExtension.lowercased() == "app")
                let isPackage = (values.isPackage == true) || isApp
                let isDirectory = (values.isDirectory == true)

                // Skip intermediate regular directories (we scan their file or package contents)
                if isDirectory && !isPackage {
                    let dirName = fileURL.lastPathComponent
                    if dirName == "node_modules" || dirName == ".git" || dirName == "Library" || dirName == "__pycache__" {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // If it's a package/app, ensure we don't descend into it
                if isPackage {
                    enumerator.skipDescendants()
                }

                batchCounter += 1
                if batchCounter >= 25 {
                    let display = fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    progressCallback(batchCounter, display)
                    batchCounter = 0
                }

                // Determine last opened / used date
                let mdLastUsed = spotlightLastUsedDate(for: fileURL)
                let modDate = values.contentModificationDate
                let createDate = values.creationDate
                let accessDate = values.contentAccessDate
                let addedDate = values.addedToDirectoryDate

                let referenceDate: Date
                let dateSource: DateSourceKind

                if let mdLastUsed = mdLastUsed {
                    if isApp {
                        referenceDate = mdLastUsed
                    } else if let modDate = modDate, modDate > mdLastUsed {
                        referenceDate = modDate
                    } else {
                        referenceDate = mdLastUsed
                    }
                    dateSource = .spotlightLastUsed
                } else if isApp {
                    // App has no Spotlight LastUsedDate -> never opened (or not indexed)
                    // Use the most recent among addedDate, modDate, createDate
                    let fallback = [addedDate, modDate, createDate].compactMap { $0 }.max() ?? now
                    referenceDate = fallback
                    dateSource = .neverOpenedInstalled
                } else {
                    // Regular file without Spotlight LastUsedDate
                    // Use the most recent among modification, creation, or access date
                    let fallback = [modDate, createDate, accessDate].compactMap { $0 }.max() ?? now
                    referenceDate = fallback
                    dateSource = .fileSystemAccess
                }

                let components = calendar.dateComponents([.day], from: referenceDate, to: now)
                let daysInactive = max(0, components.day ?? 0)

                // Calculate size
                let sizeBytes: Int64
                if isPackage {
                    sizeBytes = calculateDirectorySize(at: fileURL)
                } else {
                    sizeBytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                }

                let name = values.name ?? fileURL.lastPathComponent
                let category = ItemCategory.categorize(url: fileURL, isApplication: isApp)

                let item = ScannedItem(
                    id: fileURL.standardizedFileURL.path,
                    url: fileURL,
                    name: name,
                    isApplication: isApp,
                    category: category,
                    sizeBytes: sizeBytes,
                    lastReferenceDate: referenceDate,
                    lastOpenedDate: mdLastUsed,
                    modificationDate: modDate,
                    creationDate: createDate,
                    dateSource: dateSource,
                    daysSinceLastUse: daysInactive
                )
                results.append(item)
            }

            if batchCounter > 0 {
                progressCallback(batchCounter, rootURL.path)
            }

            return results
        }.value
    }

    nonisolated private static func spotlightLastUsedDate(for url: URL) -> Date? {
        guard let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return nil
        }
        if let attr = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
            return attr
        }
        return nil
    }

    nonisolated private static func calculateDirectorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let values = try? fileURL.resourceValues(forKeys: Set(keys)),
               values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }
}
