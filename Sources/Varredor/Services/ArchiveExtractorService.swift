import Foundation
import AppKit

@MainActor
final class ArchiveExtractorService: ObservableObject {
    static let shared = ArchiveExtractorService()

    @Published var activeModule: AppModule = .cleaner
    @Published var jobs: [ArchiveJobItem] = []
    @Published var selectedJobID: String? = nil

    // Extraction Preferences
    @Published var destinationMode: ArchiveDestinationMode = .sameAsArchive
    @Published var customDestinationURL: URL? = nil
    @Published var createSubfolder: Bool = true
    @Published var overwritePolicy: ArchiveOverwritePolicy = .overwrite
    @Published var autoExtractOnAdd: Bool = false
    @Published var trashArchiveAfterExtract: Bool = false
    @Published var revealInFinderAfterExtract: Bool = true
    @Published var defaultPassword: String = ""

    // Password Prompt State
    @Published var passwordPromptJobID: String? = nil
    @Published var showPasswordSheet: Bool = false

    // Status Banner
    @Published var bannerMessage: String? = nil
    @Published var bannerIsError: Bool = false

    // Batch state
    @Published var isBatchExtracting: Bool = false

    // MARK: - Compression (Create Archive) State
    @Published var compressionItems: [CompressionSourceItem] = []
    @Published var compressionFormat: CompressionFormat = .zip
    @Published var compressionLevel: CompressionLevel = .normal
    @Published var compressionBatchMode: CompressionBatchMode = .singleArchive
    @Published var compressionOutputName: String = ""
    @Published var compressionDestinationMode: ArchiveDestinationMode = .sameAsArchive
    @Published var compressionCustomDestinationURL: URL? = nil
    @Published var excludeMacOSMetadata: Bool = true
    @Published var compressionUsePassword: Bool = false
    @Published var compressionPassword: String = ""
    @Published var trashSourceAfterCompress: Bool = false
    @Published var revealAfterCompress: Bool = true
    @Published var isCompressing: Bool = false
    @Published var compressionStepText: String = ""
    @Published var lastCompressionOutcome: CompressionOutcome? = nil
    @Published var compressionBannerMessage: String? = nil
    @Published var compressionBannerIsError: Bool = false

    var selectedJob: ArchiveJobItem? {
        guard let id = selectedJobID else { return jobs.first }
        return jobs.first(where: { $0.id == id }) ?? jobs.first
    }

    // MARK: - External Engine Discovery

    nonisolated static func findExecutable(_ names: [String]) -> String? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let fm = FileManager.default
        for name in names {
            for dir in searchPaths {
                let full = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: full) {
                    return full
                }
            }
        }
        return nil
    }

    var availableEnginesSummary: String {
        var list = ["libarchive (bsdtar)", "unzip", "hdiutil", "gzip / bzip2"]
        if Self.findExecutable(["xz"]) != nil {
            list.append("xz")
        }
        if Self.findExecutable(["7zz", "7z", "7za"]) != nil {
            list.append("7-Zip")
        }
        if Self.findExecutable(["unar"]) != nil {
            list.append("The Unarchiver (unar)")
        }
        if Self.findExecutable(["unrar"]) != nil {
            list.append("unrar")
        }
        return list.joined(separator: " • ")
    }

    // MARK: - Adding Archives (Drag & Drop, Finder Open, Cleaner Tab)

    func openArchivesFromFinder(_ urls: [URL], autoSwitchModule: Bool = true) {
        if autoSwitchModule {
            activeModule = .unpacker
        }
        addArchives(urls)
    }

    func addArchives(_ urls: [URL]) {
        let fm = FileManager.default
        var newlyAddedIDs: [String] = []

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            if let existingIdx = jobs.firstIndex(where: { $0.id == url.path }) {
                selectedJobID = jobs[existingIdx].id
                newlyAddedIDs.append(jobs[existingIdx].id)
                continue
            }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
            let modDate = values?.contentModificationDate
            let format = ArchiveFormat.detect(from: url)

            let job = ArchiveJobItem(
                id: url.path,
                url: url,
                name: url.lastPathComponent,
                format: format,
                compressedSizeBytes: size,
                modificationDate: modDate,
                entries: [],
                status: .queued,
                isEncrypted: false,
                password: defaultPassword.isEmpty ? nil : defaultPassword
            )

            jobs.insert(job, at: 0)
            newlyAddedIDs.append(job.id)
        }

        if let firstNew = newlyAddedIDs.first {
            selectedJobID = firstNew
        }

        for id in newlyAddedIDs {
            Task {
                await inspectArchive(jobID: id, thenExtractIfAuto: autoExtractOnAdd)
            }
        }
    }

    func removeJob(_ jobID: String) {
        jobs.removeAll { $0.id == jobID }
        if selectedJobID == jobID {
            selectedJobID = jobs.first?.id
        }
    }

    func clearCompletedJobs() {
        jobs.removeAll { $0.status.isCompleted }
        if let sel = selectedJobID, !jobs.contains(where: { $0.id == sel }) {
            selectedJobID = jobs.first?.id
        }
    }

    func clearAllJobs() {
        jobs.removeAll()
        selectedJobID = nil
    }

    // MARK: - Archive Inspection

    func inspectArchive(jobID: String, thenExtractIfAuto: Bool = false) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]
        jobs[index].status = .inspecting

        let passwordToUse = job.password ?? (defaultPassword.isEmpty ? nil : defaultPassword)
        let url = job.url
        let format = job.format

        let result = await Task.detached(priority: .userInitiated) {
            Self.performInspection(url: url, format: format, password: passwordToUse)
        }.value

        guard let updatedIdx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[updatedIdx].entries = result.entries
        jobs[updatedIdx].isEncrypted = result.isEncrypted
        jobs[updatedIdx].engineUsed = result.engineUsed

        if let passError = result.passwordRequiredMessage {
            jobs[updatedIdx].status = .passwordRequired(passError)
            self.passwordPromptJobID = jobID
            self.showPasswordSheet = true
            return
        } else if let errorMsg = result.errorMessage {
            jobs[updatedIdx].status = .failed(errorMsg)
            return
        } else {
            jobs[updatedIdx].status = .ready
        }

        if thenExtractIfAuto {
            await extractArchive(jobID: jobID, selectedEntryIDs: nil)
        }
    }

    private struct InspectionResult: Sendable {
        var entries: [ArchiveEntry] = []
        var isEncrypted: Bool = false
        var engineUsed: String = "libarchive (bsdtar)"
        var passwordRequiredMessage: String? = nil
        var errorMessage: String? = nil
    }

    nonisolated private static func performInspection(
        url: URL,
        format: ArchiveFormat,
        password: String?
    ) -> InspectionResult {
        // 1. Single-stream compressed files (.gz, .bz2, .xz that are not .tar.*)
        if format.isSingleStreamCompression {
            let innerName = ArchiveFormat.baseArchiveName(for: url)
            var uncompressedSize: Int64 = 0
            if format == .gzip {
                let gzOut = runCommand("/usr/bin/gzip", arguments: ["-l", url.path])
                if gzOut.exitCode == 0 {
                    // Parse second line of `gzip -l`: compressed uncompressed ratio uncompressed_name
                    let lines = gzOut.stdout.split(separator: "\n")
                    if let lastLine = lines.last {
                        let cols = lastLine.split(whereSeparator: { $0.isWhitespace })
                        if cols.count >= 2, let uncomp = Int64(cols[1]) {
                            uncompressedSize = max(0, uncomp)
                        }
                    }
                }
            }
            let entry = ArchiveEntry(
                id: innerName,
                relativePath: innerName,
                name: innerName,
                parentFolder: "/",
                isDirectory: false,
                uncompressedSize: uncompressedSize,
                modificationDate: nil,
                permissions: "-rw-r--r--"
            )
            let engine = format == .gzip ? "gzip" : (format == .bzip2 ? "bzip2" : "xz / liblzma")
            return InspectionResult(entries: [entry], isEncrypted: false, engineUsed: engine)
        }

        // 2. Check if ZIP has encrypted entries via zipinfo
        var zipEncrypted = false
        if format == .zip {
            let zipInfoOut = runCommand("/usr/bin/zipinfo", arguments: [url.path])
            if zipInfoOut.exitCode == 0 {
                for line in zipInfoOut.stdout.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.first == "-" || trimmed.first == "d" || trimmed.first == "l" else { continue }
                    let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
                    if tokens.count >= 5 {
                        let statusField = String(tokens[4])
                        if statusField.first == "T" || statusField.first == "B" {
                            zipEncrypted = true
                            break
                        }
                    }
                }
            }
        }

        // 3. Try bsdtar -tvf first (supports zip, rar, 7z, tar.*, iso, xar, cpio, cab, etc.)
        let effectivePass = (password?.isEmpty == false) ? password! : "__varredor_nopass__"
        let bsdArgs = ["--passphrase", effectivePass, "-tvf", url.path]
        let bsdResult = runCommand("/usr/bin/bsdtar", arguments: bsdArgs)

        let combinedOutput = (bsdResult.stdout + "\n" + bsdResult.stderr).lowercased()
        if combinedOutput.contains("passphrase") || combinedOutput.contains("encrypted") || combinedOutput.contains("password") {
            let parsedEntries = parseBsdtarOutput(bsdResult.stdout)
            if password == nil || password?.isEmpty == true || bsdResult.exitCode != 0 {
                return InspectionResult(
                    entries: parsedEntries,
                    isEncrypted: true,
                    engineUsed: "libarchive (bsdtar)",
                    passwordRequiredMessage: "Este arquivo é protegido por senha."
                )
            }
        }

        if bsdResult.exitCode == 0 {
            let entries = parseBsdtarOutput(bsdResult.stdout)
            if !entries.isEmpty {
                return InspectionResult(
                    entries: entries,
                    isEncrypted: zipEncrypted,
                    engineUsed: "libarchive (bsdtar)"
                )
            }
        }

        // 4. If it's a Disk Image (.iso / .dmg) and bsdtar didn't list it (e.g. UDF / HFS+ / APFS DMG or ISO), use hdiutil
        if format.isDiskImage {
            if let hdiResult = inspectWithHdiutil(url: url, password: password) {
                return hdiResult
            }
        }

        // 5. Try external 7zz / 7z / lsar if available (for solid RAR5/7z or encrypted headers)
        if let sevenZipPath = findExecutable(["7zz", "7z", "7za"]) {
            let passArg = "-p\(password ?? "")"
            let szOut = runCommand(sevenZipPath, arguments: ["l", "-slt", "-y", passArg, url.path])
            let szCombined = (szOut.stdout + "\n" + szOut.stderr).lowercased()
            if szCombined.contains("wrong password") || szCombined.contains("can not open encrypted archive") {
                return InspectionResult(
                    entries: [],
                    isEncrypted: true,
                    engineUsed: "7-Zip",
                    passwordRequiredMessage: "Arquivo criptografado (cabeçalhos protegidos por senha)."
                )
            }
            if szOut.exitCode == 0 {
                let entries = parseSevenZipSltOutput(szOut.stdout)
                if !entries.isEmpty {
                    let encrypted = szOut.stdout.contains("Encrypted = +")
                    return InspectionResult(entries: entries, isEncrypted: encrypted, engineUsed: "7-Zip")
                }
            }
        }

        if let lsarPath = findExecutable(["lsar"]) {
            var args = ["-l"]
            if let p = password, !p.isEmpty {
                args.append(contentsOf: ["-p", p])
            }
            args.append(url.path)
            let lsarOut = runCommand(lsarPath, arguments: args)
            if lsarOut.stdout.lowercased().contains("password") || lsarOut.stderr.lowercased().contains("password") {
                return InspectionResult(
                    entries: [],
                    isEncrypted: true,
                    engineUsed: "The Unarchiver (lsar)",
                    passwordRequiredMessage: "Arquivo protegido por senha."
                )
            }
        }

        let errDetail = bsdResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return InspectionResult(
            entries: [],
            isEncrypted: zipEncrypted,
            engineUsed: "libarchive (bsdtar)",
            errorMessage: errDetail.isEmpty ? "Formato não reconhecido ou arquivo corrompido." : errDetail
        )
    }

    nonisolated private static func parseBsdtarOutput(_ stdout: String) -> [ArchiveEntry] {
        var results: [ArchiveEntry] = []
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)

        for rawLine in lines {
            let line = String(rawLine)
            // Typical bsdtar -tvf format:
            // drwxr-xr-x  0 501    20          0 Oct 25 16:40 folder/
            // -rw-r--r--  0 501    20       1234 Oct 25 16:40 folder/file name.txt
            let scanner = Scanner(string: line)
            scanner.charactersToBeSkipped = nil

            func skipSpaces() {
                _ = scanner.scanCharacters(from: .whitespaces)
            }
            func scanToken() -> String? {
                skipSpaces()
                return scanner.scanUpToCharacters(from: .whitespaces)
            }

            guard let perms = scanToken(),
                  let _ = scanToken(), // links
                  let _ = scanToken(), // owner
                  let _ = scanToken(), // group
                  let sizeStr = scanToken(), // size
                  let _ = scanToken(), // month
                  let _ = scanToken(), // day
                  let _ = scanToken()  // time or year
            else {
                continue
            }

            // Skip single whitespace after time/year token to preserve leading spaces in filenames if any
            _ = scanner.scanCharacters(from: .whitespaces)
            let remainingPath = String(line[scanner.currentIndex...]).trimmingCharacters(in: .newlines)
            guard !remainingPath.isEmpty else { continue }

            // Handle symlink arrows if present ("link -> target")
            let cleanPath: String
            if perms.first == "l", let arrowRange = remainingPath.range(of: " -> ") {
                cleanPath = String(remainingPath[..<arrowRange.lowerBound])
            } else {
                cleanPath = remainingPath
            }

            let isDir = perms.first == "d" || cleanPath.hasSuffix("/")
            let normalizedPath = cleanPath.hasSuffix("/") ? String(cleanPath.dropLast()) : cleanPath
            guard !normalizedPath.isEmpty, normalizedPath != "." else { continue }

            let nsPath = normalizedPath as NSString
            let name = nsPath.lastPathComponent
            let parent = nsPath.deletingLastPathComponent
            let size = Int64(sizeStr) ?? 0

            results.append(
                ArchiveEntry(
                    id: cleanPath,
                    relativePath: normalizedPath,
                    name: name.isEmpty ? normalizedPath : name,
                    parentFolder: parent.isEmpty ? "/" : parent,
                    isDirectory: isDir,
                    uncompressedSize: isDir ? 0 : size,
                    modificationDate: nil,
                    permissions: perms
                )
            )
        }

        return results
    }

    nonisolated private static func parseSevenZipSltOutput(_ stdout: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let blocks = stdout.components(separatedBy: "\n\n")
        for block in blocks {
            var path: String?
            var size: Int64 = 0
            var isFolder = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("Path = ") {
                    path = String(line.dropFirst("Path = ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if line.hasPrefix("Size = ") {
                    let s = String(line.dropFirst("Size = ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    size = Int64(s) ?? 0
                } else if line.hasPrefix("Folder = +") {
                    isFolder = true
                }
            }
            if let p = path, !p.isEmpty {
                let nsPath = p as NSString
                entries.append(
                    ArchiveEntry(
                        id: p,
                        relativePath: p,
                        name: nsPath.lastPathComponent,
                        parentFolder: nsPath.deletingLastPathComponent.isEmpty ? "/" : nsPath.deletingLastPathComponent,
                        isDirectory: isFolder,
                        uncompressedSize: isFolder ? 0 : size,
                        modificationDate: nil,
                        permissions: isFolder ? "drwxr-xr-x" : "-rw-r--r--"
                    )
                )
            }
        }
        if entries.count > 1 {
            // In 7z -slt, the first block with Path = <archive_path> is the archive header itself
            entries.removeFirst()
        }
        return entries
    }

    nonisolated private static func inspectWithHdiutil(url: URL, password: String?) -> InspectionResult? {
        let mountParent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VarredorMount_\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: mountParent, withIntermediateDirectories: true)
        defer {
            _ = runCommand("/usr/bin/hdiutil", arguments: ["detach", "-force", mountParent.path])
            try? fm.removeItem(at: mountParent)
        }

        var args = ["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mountParent.path]
        if password != nil {
            args.append("-stdinpass")
        }
        args.append(url.path)

        let attachOut = runCommand("/usr/bin/hdiutil", arguments: args, stdinString: password)
        let combined = (attachOut.stdout + "\n" + attachOut.stderr).lowercased()
        if combined.contains("authentication failed") || combined.contains("passphrase") || combined.contains("password") {
            return InspectionResult(
                entries: [],
                isEncrypted: true,
                engineUsed: "macOS DiskImage (hdiutil)",
                passwordRequiredMessage: "Esta imagem de disco (.dmg/.iso) é criptografada e requer senha."
            )
        }

        guard attachOut.exitCode == 0 else { return nil }

        var entries: [ArchiveEntry] = []
        if let enumerator = fm.enumerator(
            at: mountParent,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let relPath = fileURL.path.replacingOccurrences(of: mountParent.path + "/", with: "")
                guard !relPath.isEmpty, relPath != mountParent.path else { continue }
                let vals = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = vals?.isDirectory ?? false
                let size = Int64(vals?.fileSize ?? 0)
                let nsRel = relPath as NSString
                entries.append(
                    ArchiveEntry(
                        id: relPath,
                        relativePath: relPath,
                        name: fileURL.lastPathComponent,
                        parentFolder: nsRel.deletingLastPathComponent.isEmpty ? "/" : nsRel.deletingLastPathComponent,
                        isDirectory: isDir,
                        uncompressedSize: isDir ? 0 : size,
                        modificationDate: vals?.contentModificationDate,
                        permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--"
                    )
                )
            }
        }

        return InspectionResult(entries: entries, isEncrypted: false, engineUsed: "macOS DiskImage (hdiutil)")
    }

    // MARK: - Extraction

    func resolveBaseDestinationDirectory(for archiveURL: URL) -> URL {
        switch destinationMode {
        case .sameAsArchive:
            return archiveURL.deletingLastPathComponent()
        case .downloads:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? archiveURL.deletingLastPathComponent()
        case .desktop:
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? archiveURL.deletingLastPathComponent()
        case .custom:
            return customDestinationURL ?? archiveURL.deletingLastPathComponent()
        }
    }

    func extractArchive(jobID: String, selectedEntryIDs: Set<String>? = nil) async {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[idx]

        let passwordToUse = job.password ?? (defaultPassword.isEmpty ? nil : defaultPassword)
        if job.isEncrypted && (passwordToUse == nil || passwordToUse?.isEmpty == true) {
            jobs[idx].status = .passwordRequired("Digite a senha para descompactar \(job.name).")
            passwordPromptJobID = jobID
            showPasswordSheet = true
            return
        }

        let baseDestDir = resolveBaseDestinationDirectory(for: job.url)
        let shouldCreateSubfolder = createSubfolder
        let overwrite = (overwritePolicy == .overwrite)
        let entriesToFilter: [String]? = {
            guard let sel = selectedEntryIDs, !sel.isEmpty else { return nil }
            return Array(sel)
        }()

        jobs[idx].status = .extracting(progress: 0.15, currentStep: "Preparando destino...")

        let archiveURL = job.url
        let format = job.format
        let totalExpectedCount = entriesToFilter?.count ?? max(1, job.entries.count)

        let extractionResult = await Task.detached(priority: .userInitiated) {
            Self.performExtraction(
                archiveURL: archiveURL,
                format: format,
                baseDestinationDir: baseDestDir,
                createSubfolder: shouldCreateSubfolder,
                overwrite: overwrite,
                password: passwordToUse,
                specificEntryPaths: entriesToFilter,
                expectedCount: totalExpectedCount
            )
        }.value

        guard let updatedIdx = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        if let passError = extractionResult.passwordRequiredMessage {
            jobs[updatedIdx].isEncrypted = true
            jobs[updatedIdx].status = .passwordRequired(passError)
            self.passwordPromptJobID = jobID
            self.showPasswordSheet = true
            return
        }

        if let errorMsg = extractionResult.errorMessage {
            jobs[updatedIdx].status = .failed(errorMsg)
            self.bannerIsError = true
            self.bannerMessage = "Falha ao extrair \(job.name): \(errorMsg)"
            return
        }

        let outputURL = extractionResult.outputDirectoryURL
        jobs[updatedIdx].status = .completed(destinationURL: outputURL, extractedCount: extractionResult.extractedCount)
        jobs[updatedIdx].lastOutputURL = outputURL
        self.bannerIsError = false
        self.bannerMessage = "Arquivo \"\(job.name)\" descompactado com sucesso em \(outputURL.lastPathComponent)!"

        if trashArchiveAfterExtract && selectedEntryIDs == nil {
            try? FileManager.default.trashItem(at: archiveURL, resultingItemURL: nil)
        }

        if revealInFinderAfterExtract && !isBatchExtracting {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    func extractAllQueued() async {
        let targetIDs = jobs.filter { !$0.status.isCompleted && !$0.status.isBusy }.map(\.id)
        guard !targetIDs.isEmpty else { return }

        isBatchExtracting = true
        var completedURLs: [URL] = []

        for id in targetIDs {
            await extractArchive(jobID: id, selectedEntryIDs: nil)
            if let job = jobs.first(where: { $0.id == id }),
               let outURL = job.lastOutputURL {
                completedURLs.append(outURL)
            }
        }

        isBatchExtracting = false

        if !completedURLs.isEmpty {
            bannerIsError = false
            bannerMessage = "Extração em lote concluída: \(completedURLs.count) arquivo(s) descompactado(s)!"
            if revealInFinderAfterExtract {
                NSWorkspace.shared.activateFileViewerSelecting(completedURLs)
            }
        }
    }

    func supplyPassword(_ password: String, applyToAll: Bool, forJobID jobID: String) {
        if applyToAll {
            defaultPassword = password
            for i in jobs.indices {
                if jobs[i].password == nil || jobs[i].status.needsPassword {
                    jobs[i].password = password
                }
            }
        }
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].password = password
        }
        showPasswordSheet = false
        passwordPromptJobID = nil

        Task {
            await inspectArchive(jobID: jobID, thenExtractIfAuto: false)
            if let idx = jobs.firstIndex(where: { $0.id == jobID }),
               jobs[idx].status == .ready {
                await extractArchive(jobID: jobID, selectedEntryIDs: nil)
            }
        }
    }

    // MARK: - Quick Preview Single Entry Inside Archive

    func quickPreviewEntry(_ entry: ArchiveEntry, in job: ArchiveJobItem) {
        guard !entry.isDirectory else { return }
        Task {
            let tempPreviewDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VarredorPreview_\(UUID().uuidString)", isDirectory: true)
            let passwordToUse = job.password ?? (defaultPassword.isEmpty ? nil : defaultPassword)

            let res = await Task.detached(priority: .userInitiated) {
                Self.performExtraction(
                    archiveURL: job.url,
                    format: job.format,
                    baseDestinationDir: tempPreviewDir,
                    createSubfolder: false,
                    overwrite: true,
                    password: passwordToUse,
                    specificEntryPaths: [entry.id],
                    expectedCount: 1
                )
            }.value

            if let err = res.passwordRequiredMessage {
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].isEncrypted = true
                    jobs[idx].status = .passwordRequired(err)
                }
                self.passwordPromptJobID = job.id
                self.showPasswordSheet = true
                return
            }

            let previewFileURL = tempPreviewDir.appendingPathComponent(entry.relativePath)
            if FileManager.default.fileExists(atPath: previewFileURL.path) {
                NSWorkspace.shared.open(previewFileURL)
            } else {
                NSWorkspace.shared.open(tempPreviewDir)
            }
        }
    }

    // MARK: - Core Extraction Worker

    private struct ExtractionWorkerResult: Sendable {
        var outputDirectoryURL: URL
        var extractedCount: Int = 0
        var passwordRequiredMessage: String? = nil
        var errorMessage: String? = nil
    }

    nonisolated private static func performExtraction(
        archiveURL: URL,
        format: ArchiveFormat,
        baseDestinationDir: URL,
        createSubfolder: Bool,
        overwrite: Bool,
        password: String?,
        specificEntryPaths: [String]?,
        expectedCount: Int
    ) -> ExtractionWorkerResult {
        let fm = FileManager.default
        let targetDir: URL
        if createSubfolder {
            let folderName = ArchiveFormat.baseArchiveName(for: archiveURL)
            let candidate = baseDestinationDir.appendingPathComponent(folderName, isDirectory: true)
            if !overwrite && fm.fileExists(atPath: candidate.path) {
                targetDir = uniqueDirectoryURL(for: candidate)
            } else {
                targetDir = candidate
            }
        } else {
            targetDir = baseDestinationDir
        }

        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            return ExtractionWorkerResult(
                outputDirectoryURL: targetDir,
                errorMessage: "Não foi possível criar a pasta de destino: \(error.localizedDescription)"
            )
        }

        // 1. Single-stream compressed files (.gz, .bz2, .xz)
        if format.isSingleStreamCompression {
            let outputFileName = ArchiveFormat.baseArchiveName(for: archiveURL)
            let outputFileURL = targetDir.appendingPathComponent(outputFileName)
            let toolPath: String
            switch format {
            case .gzip:
                toolPath = "/usr/bin/gzip"
            case .bzip2:
                toolPath = "/usr/bin/bzip2"
            case .xz:
                toolPath = findExecutable(["xz"]) ?? "/usr/bin/bsdtar"
            default:
                toolPath = "/usr/bin/gzip"
            }

            if toolPath.hasSuffix("xz") || toolPath.hasSuffix("gzip") || toolPath.hasSuffix("bzip2") {
                let ok = decompressSingleStream(toolPath: toolPath, inputURL: archiveURL, outputURL: outputFileURL)
                if ok {
                    return ExtractionWorkerResult(outputDirectoryURL: createSubfolder ? targetDir : outputFileURL, extractedCount: 1)
                }
            }
            return ExtractionWorkerResult(
                outputDirectoryURL: targetDir,
                errorMessage: "Falha ao descomprimir stream \(format.rawValue)."
            )
        }

        // 2. Primary engine: bsdtar (supports .zip, .rar, .7z, .tar, .tar.gz, .tar.bz2, .tar.xz, .iso, .xar, .cpio, .cab)
        let effectivePass = (password?.isEmpty == false) ? password! : "__varredor_nopass__"
        var bsdArgs = ["--passphrase", effectivePass, "-xf", archiveURL.path, "-C", targetDir.path]
        if !overwrite {
            bsdArgs.append("-k")
        }
        if let paths = specificEntryPaths, !paths.isEmpty {
            bsdArgs.append("--")
            bsdArgs.append(contentsOf: paths)
        }

        let bsdOut = runCommand("/usr/bin/bsdtar", arguments: bsdArgs)
        let combined = (bsdOut.stdout + "\n" + bsdOut.stderr).lowercased()

        if combined.contains("incorrect passphrase") || combined.contains("passphrase required") || combined.contains("empty passphrase") {
            return ExtractionWorkerResult(
                outputDirectoryURL: targetDir,
                passwordRequiredMessage: "Senha incorreta ou necessária para extrair este arquivo."
            )
        }

        if bsdOut.exitCode == 0 {
            return ExtractionWorkerResult(
                outputDirectoryURL: targetDir,
                extractedCount: expectedCount
            )
        }

        // 3. Fallback for ZIP with special encodings or WinZip AES if unzip or 7zz is available
        if format == .zip {
            var unzipArgs = overwrite ? ["-o"] : ["-n"]
            if let p = password, !p.isEmpty {
                unzipArgs.append(contentsOf: ["-P", p])
            } else {
                unzipArgs.append(contentsOf: ["-P", "__varredor_nopass__"])
            }
            unzipArgs.append(archiveURL.path)
            if let paths = specificEntryPaths, !paths.isEmpty {
                unzipArgs.append(contentsOf: paths)
            }
            unzipArgs.append(contentsOf: ["-d", targetDir.path])

            let unzipOut = runCommand("/usr/bin/unzip", arguments: unzipArgs)
            let unzipComb = (unzipOut.stdout + "\n" + unzipOut.stderr).lowercased()
            if unzipComb.contains("incorrect password") {
                return ExtractionWorkerResult(
                    outputDirectoryURL: targetDir,
                    passwordRequiredMessage: "Senha incorreta ou necessária para este arquivo ZIP."
                )
            }
            if unzipOut.exitCode == 0 {
                return ExtractionWorkerResult(outputDirectoryURL: targetDir, extractedCount: expectedCount)
            }
        }

        // 4. Fallback for Disk Images (.iso / .dmg) via hdiutil
        if format.isDiskImage {
            if let hdiExtract = extractWithHdiutil(
                archiveURL: archiveURL,
                targetDir: targetDir,
                password: password,
                specificEntryPaths: specificEntryPaths,
                expectedCount: expectedCount
            ) {
                return hdiExtract
            }
        }

        // 5. Fallback for 7-Zip / unar / unrar if installed
        if let sevenZipPath = findExecutable(["7zz", "7z", "7za"]) {
            var szArgs = ["x", overwrite ? "-aoa" : "-aos", "-y", "-p\(password ?? "")", "-o\(targetDir.path)", archiveURL.path]
            if let paths = specificEntryPaths, !paths.isEmpty {
                szArgs.append(contentsOf: paths)
            }
            let szOut = runCommand(sevenZipPath, arguments: szArgs)
            let szComb = (szOut.stdout + "\n" + szOut.stderr).lowercased()
            if szComb.contains("wrong password") {
                return ExtractionWorkerResult(
                    outputDirectoryURL: targetDir,
                    passwordRequiredMessage: "Senha incorreta para este arquivo."
                )
            }
            if szOut.exitCode == 0 {
                return ExtractionWorkerResult(outputDirectoryURL: targetDir, extractedCount: expectedCount)
            }
        }

        if let unarPath = findExecutable(["unar"]) {
            var unarArgs = [overwrite ? "-f" : "-s", "-o", targetDir.path]
            if let p = password, !p.isEmpty {
                unarArgs.append(contentsOf: ["-p", p])
            }
            unarArgs.append(archiveURL.path)
            let unarOut = runCommand(unarPath, arguments: unarArgs)
            if unarOut.exitCode == 0 {
                return ExtractionWorkerResult(outputDirectoryURL: targetDir, extractedCount: expectedCount)
            }
        }

        let cleanErr = bsdOut.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractionWorkerResult(
            outputDirectoryURL: targetDir,
            errorMessage: cleanErr.isEmpty ? "Não foi possível extrair o arquivo." : cleanErr
        )
    }

    nonisolated private static func extractWithHdiutil(
        archiveURL: URL,
        targetDir: URL,
        password: String?,
        specificEntryPaths: [String]?,
        expectedCount: Int
    ) -> ExtractionWorkerResult? {
        let mountParent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VarredorExtractMount_\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: mountParent, withIntermediateDirectories: true)
        defer {
            _ = runCommand("/usr/bin/hdiutil", arguments: ["detach", "-force", mountParent.path])
            try? fm.removeItem(at: mountParent)
        }

        var args = ["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mountParent.path]
        if password != nil {
            args.append("-stdinpass")
        }
        args.append(archiveURL.path)

        let attachOut = runCommand("/usr/bin/hdiutil", arguments: args, stdinString: password)
        let combined = (attachOut.stdout + "\n" + attachOut.stderr).lowercased()
        if combined.contains("authentication failed") || combined.contains("passphrase") || combined.contains("password") {
            return ExtractionWorkerResult(
                outputDirectoryURL: targetDir,
                passwordRequiredMessage: "Senha necessária para montar e extrair esta imagem de disco."
            )
        }

        guard attachOut.exitCode == 0 else { return nil }

        var copiedCount = 0
        if let paths = specificEntryPaths, !paths.isEmpty {
            for rel in paths {
                let src = mountParent.appendingPathComponent(rel)
                let dst = targetDir.appendingPathComponent(rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                if (try? fm.copyItem(at: src, to: dst)) != nil {
                    copiedCount += 1
                }
            }
        } else {
            // Use ditto to preserve macOS bundles/symlinks cleanly
            let dittoOut = runCommand("/usr/bin/ditto", arguments: [mountParent.path, targetDir.path])
            if dittoOut.exitCode == 0 {
                copiedCount = expectedCount
            } else {
                return ExtractionWorkerResult(
                    outputDirectoryURL: targetDir,
                    errorMessage: "Erro ao copiar conteúdo da imagem de disco: \(dittoOut.stderr)"
                )
            }
        }

        return ExtractionWorkerResult(outputDirectoryURL: targetDir, extractedCount: max(1, copiedCount))
    }

    nonisolated private static func decompressSingleStream(toolPath: String, inputURL: URL, outputURL: URL) -> Bool {
        let fm = FileManager.default
        fm.createFile(atPath: outputURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: outputURL) else { return false }
        defer { try? outHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["-dc", inputURL.path]
        process.standardOutput = outHandle
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func uniqueDirectoryURL(for base: URL) -> URL {
        let fm = FileManager.default
        var counter = 2
        let parent = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        while true {
            let candidate = parent.appendingPathComponent("\(name) (\(counter))", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - Subprocess Helper

    private struct CommandOutput: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated private static func runCommand(
        _ launchPath: String,
        arguments: [String],
        stdinString: String? = nil
    ) -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let input = stdinString {
            let inPipe = Pipe()
            process.standardInput = inPipe
            if let data = (input + "\n").data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            return CommandOutput(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outStr = String(data: outData, encoding: .utf8)
            ?? String(data: outData, encoding: .isoLatin1)
            ?? ""
        let errStr = String(data: errData, encoding: .utf8)
            ?? String(data: errData, encoding: .isoLatin1)
            ?? ""

        return CommandOutput(exitCode: process.terminationStatus, stdout: outStr, stderr: errStr)
    }

    // MARK: - Compression (Create Archive) Implementation

    func openItemsForCompression(_ urls: [URL], autoSwitchModule: Bool = true) {
        if autoSwitchModule {
            activeModule = .compressor
        }
        addCompressionItems(urls)
    }

    func addCompressionItems(_ urls: [URL]) {
        let fm = FileManager.default
        var addedIDs: [String] = []

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard !compressionItems.contains(where: { $0.id == url.path }) else { continue }

            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
            let initialSize = isDir.boolValue ? 0 : Int64(vals?.totalFileSize ?? vals?.fileSize ?? 0)

            let item = CompressionSourceItem(
                id: url.path,
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir.boolValue,
                sizeBytes: initialSize,
                itemCount: 1
            )
            compressionItems.append(item)
            addedIDs.append(item.id)
        }

        if compressionOutputName.trimmingCharacters(in: .whitespaces).isEmpty,
           let first = compressionItems.first {
            let base = first.isDirectory ? first.name : first.url.deletingPathExtension().lastPathComponent
            compressionOutputName = compressionItems.count > 1 ? "\(base)_Pacote" : base
        }

        for id in addedIDs {
            guard let item = compressionItems.first(where: { $0.id == id }), item.isDirectory else { continue }
            let targetURL = item.url
            Task {
                let stats = await Task.detached(priority: .utility) {
                    Self.calculateFolderStats(url: targetURL)
                }.value
                if let idx = self.compressionItems.firstIndex(where: { $0.id == id }) {
                    self.compressionItems[idx].sizeBytes = stats.totalBytes
                    self.compressionItems[idx].itemCount = stats.fileCount
                }
            }
        }
    }

    func removeCompressionItem(_ id: String) {
        compressionItems.removeAll { $0.id == id }
        if compressionItems.isEmpty {
            compressionOutputName = ""
            lastCompressionOutcome = nil
        }
    }

    func clearCompressionItems() {
        compressionItems.removeAll()
        compressionOutputName = ""
        lastCompressionOutcome = nil
    }

    var totalCompressionInputBytes: Int64 {
        compressionItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalCompressionFileCount: Int {
        compressionItems.reduce(0) { $0 + max(1, $1.itemCount) }
    }

    func resolveCompressionDestinationDir() -> URL {
        guard let first = compressionItems.first else {
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        switch compressionDestinationMode {
        case .sameAsArchive:
            return first.url.deletingLastPathComponent()
        case .downloads:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? first.url.deletingLastPathComponent()
        case .desktop:
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? first.url.deletingLastPathComponent()
        case .custom:
            return compressionCustomDestinationURL ?? first.url.deletingLastPathComponent()
        }
    }

    func createArchive() async {
        guard !compressionItems.isEmpty, !isCompressing else { return }

        if compressionUsePassword && compressionFormat.supportsPasswordOutOfTheBox && compressionPassword.isEmpty {
            compressionBannerIsError = true
            compressionBannerMessage = "Digite uma senha para proteger o arquivo compactado ou desative a proteção por senha."
            return
        }

        isCompressing = true
        compressionStepText = "Preparando arquivos para compactação..."
        lastCompressionOutcome = nil
        compressionBannerMessage = nil

        let itemsSnapshot = compressionItems
        let format = compressionFormat
        let level = compressionLevel
        let batchMode = compressionBatchMode
        let destDir = resolveCompressionDestinationDir()
        let excludeMeta = excludeMacOSMetadata
        let passwordToUse: String? = (compressionUsePassword && format.supportsPasswordOutOfTheBox && !compressionPassword.isEmpty)
            ? compressionPassword
            : nil
        let rawOutputName = compressionOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBaseName = itemsSnapshot.first.map {
            $0.isDirectory ? $0.name : $0.url.deletingPathExtension().lastPathComponent
        } ?? "Arquivo_Compactado"
        let effectiveBaseName = rawOutputName.isEmpty ? fallbackBaseName : rawOutputName
        let totalOriginalBytes = totalCompressionInputBytes

        let workerResult = await Task.detached(priority: .userInitiated) {
            Self.performCompressionBatch(
                items: itemsSnapshot,
                format: format,
                level: level,
                batchMode: batchMode,
                destinationDir: destDir,
                baseArchiveName: effectiveBaseName,
                excludeMacOSMeta: excludeMeta,
                password: passwordToUse
            )
        }.value

        isCompressing = false
        compressionStepText = ""

        if let err = workerResult.errorMessage {
            compressionBannerIsError = true
            compressionBannerMessage = "Erro ao compactar: \(err)"
            return
        }

        let createdURLs = workerResult.createdURLs
        let totalCompressed: Int64 = createdURLs.reduce(0) { acc, url in
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
            return acc + Int64(vals?.totalFileSize ?? vals?.fileSize ?? 0)
        }

        let outcome = CompressionOutcome(
            createdURLs: createdURLs,
            originalBytes: totalOriginalBytes,
            compressedBytes: totalCompressed
        )
        lastCompressionOutcome = outcome

        let compSizeStr = ByteCountFormatter.string(fromByteCount: totalCompressed, countStyle: .file)
        if createdURLs.count == 1, let firstOut = createdURLs.first {
            compressionBannerIsError = false
            compressionBannerMessage = "Arquivo \"\(firstOut.lastPathComponent)\" criado com sucesso (\(compSizeStr) • \(outcome.savingsPercentText) de redução)!"
        } else {
            compressionBannerIsError = false
            compressionBannerMessage = "\(createdURLs.count) arquivos compactados criados com sucesso (\(compSizeStr) no total)!"
        }

        if trashSourceAfterCompress {
            for item in itemsSnapshot {
                try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            }
            compressionItems.removeAll()
        }

        if revealAfterCompress && !createdURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(createdURLs)
        }
    }

    private struct CompressionWorkerResult: Sendable {
        var createdURLs: [URL] = []
        var errorMessage: String? = nil
    }

    nonisolated private static func performCompressionBatch(
        items: [CompressionSourceItem],
        format: CompressionFormat,
        level: CompressionLevel,
        batchMode: CompressionBatchMode,
        destinationDir: URL,
        baseArchiveName: String,
        excludeMacOSMeta: Bool,
        password: String?
    ) -> CompressionWorkerResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        switch batchMode {
        case .singleArchive:
            let outURL = uniqueArchiveFileURL(
                directory: destinationDir,
                baseName: stripKnownExtension(baseArchiveName, ext: format.fileExtension),
                ext: format.fileExtension
            )
            let sourceURLs = items.map(\.url)
            if let err = compressGroup(
                sourceURLs: sourceURLs,
                outputURL: outURL,
                format: format,
                level: level,
                excludeMacOSMeta: excludeMacOSMeta,
                password: password
            ) {
                return CompressionWorkerResult(createdURLs: [], errorMessage: err)
            }
            return CompressionWorkerResult(createdURLs: [outURL], errorMessage: nil)

        case .separateArchives:
            var created: [URL] = []
            for item in items {
                let itemBase = item.isDirectory ? item.name : item.url.deletingPathExtension().lastPathComponent
                let outURL = uniqueArchiveFileURL(
                    directory: destinationDir,
                    baseName: itemBase,
                    ext: format.fileExtension
                )
                if let err = compressGroup(
                    sourceURLs: [item.url],
                    outputURL: outURL,
                    format: format,
                    level: level,
                    excludeMacOSMeta: excludeMacOSMeta,
                    password: password
                ) {
                    return CompressionWorkerResult(createdURLs: created, errorMessage: err)
                }
                created.append(outURL)
            }
            return CompressionWorkerResult(createdURLs: created, errorMessage: nil)
        }
    }

    nonisolated private static func compressGroup(
        sourceURLs: [URL],
        outputURL: URL,
        format: CompressionFormat,
        level: CompressionLevel,
        excludeMacOSMeta: Bool,
        password: String?
    ) -> String? {
        // 1. macOS Disk Image (.dmg) via hdiutil
        if format == .dmg {
            let volName = outputURL.deletingPathExtension().lastPathComponent
            var args = ["create", "-volname", volName]
            for src in sourceURLs {
                args.append(contentsOf: ["-srcfolder", src.path])
            }
            let dmgFormat = (level == .store) ? "UDRO" : "UDZO"
            args.append(contentsOf: ["-ov", "-format", dmgFormat])
            if let p = password, !p.isEmpty {
                args.append(contentsOf: ["-encryption", "AES-256", "-stdinpass"])
            }
            args.append(outputURL.path)

            let out = runCommand("/usr/bin/hdiutil", arguments: args, stdinString: password)
            if out.exitCode != 0 {
                let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return msg.isEmpty ? "Falha ao criar imagem .dmg." : msg
            }
            return nil
        }

        // 2. 7-Zip with password if 7zz is available
        if format == .sevenZip, let p = password, !p.isEmpty,
           let sevenZipBin = findExecutable(["7zz", "7z", "7za"]) {
            var args = ["a", "-t7z", "-mx=\(level.numericLevel)", "-mhe=on", "-p\(p)", "-y", outputURL.path]
            if excludeMacOSMeta {
                args.append(contentsOf: ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"])
            }
            for src in sourceURLs {
                args.append(src.path)
            }
            let out = runCommand(sevenZipBin, arguments: args)
            if out.exitCode != 0 {
                let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return msg.isEmpty ? "Falha ao criar arquivo .7z protegido." : msg
            }
            return nil
        }

        // 3. Universal libarchive / bsdtar creation for .zip, .7z, .tar.xz, .tar.gz, .tar.bz2, .tar, .iso
        var bsdArgs: [String] = ["-cf", outputURL.path]

        var optionTokens: [String] = []

        switch format {
        case .zip:
            bsdArgs.append(contentsOf: ["--format", "zip"])
            if level == .store {
                optionTokens.append("zip:compression=store")
            } else {
                optionTokens.append("zip:compression-level=\(level.numericLevel)")
            }
            if let p = password, !p.isEmpty {
                optionTokens.append("zip:encryption=aes256")
                bsdArgs.append(contentsOf: ["--passphrase", p])
            }
        case .sevenZip:
            bsdArgs.append(contentsOf: ["--format", "7zip"])
            optionTokens.append("7zip:compression-level=\(level.numericLevel)")
        case .tarXz:
            bsdArgs.append("-J")
            optionTokens.append("xz:compression-level=\(level.numericLevel)")
        case .tarGz:
            bsdArgs.append("-z")
            optionTokens.append("gzip:compression-level=\(max(1, level.numericLevel))")
        case .tarBz2:
            bsdArgs.append("-j")
            optionTokens.append("bzip2:compression-level=\(max(1, level.numericLevel))")
        case .tar:
            bsdArgs.append(contentsOf: ["--format", "pax"])
        case .iso:
            bsdArgs.append(contentsOf: ["--format", "iso9660"])
        case .dmg:
            break
        }

        if !optionTokens.isEmpty {
            bsdArgs.append(contentsOf: ["--options", optionTokens.joined(separator: ",")])
        }

        if excludeMacOSMeta {
            bsdArgs.append(contentsOf: [
                "--exclude", ".DS_Store",
                "--exclude", "__MACOSX",
                "--exclude", "._*"
            ])
        }

        for src in sourceURLs {
            let parentDir = src.deletingLastPathComponent().path
            let itemName = src.lastPathComponent
            bsdArgs.append(contentsOf: ["-C", parentDir, itemName])
        }

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        if excludeMacOSMeta {
            env["COPYFILE_DISABLE"] = "1"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = bsdArgs
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errStr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return errStr.isEmpty ? "Falha ao criar arquivo compactado." : errStr
        }

        return nil
    }

    nonisolated private static func stripKnownExtension(_ name: String, ext: String) -> String {
        let lower = name.lowercased()
        let suffix = "." + ext.lowercased()
        if lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    nonisolated private static func uniqueArchiveFileURL(directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        let firstCandidate = directory.appendingPathComponent("\(baseName).\(ext)")
        if !fm.fileExists(atPath: firstCandidate.path) {
            return firstCandidate
        }
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) (\(counter)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    nonisolated private static func calculateFolderStats(url: URL) -> (totalBytes: Int64, fileCount: Int) {
        let fm = FileManager.default
        var total: Int64 = 0
        var count: Int = 0
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: []
        ) {
            for case let childURL as URL in enumerator {
                let vals = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey])
                if vals?.isDirectory == false {
                    total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
                    count += 1
                }
            }
        }
        return (total, max(1, count))
    }
}
