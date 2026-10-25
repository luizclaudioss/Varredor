import Foundation
import AppKit

enum UninstallMode: String, CaseIterable, Identifiable {
    case moveToTrash = "Mover tudo para a Lixeira"
    case permanentDelete = "Excluir permanentemente (sem Lixeira)"

    var id: String { rawValue }
}

struct UninstallExecutionResult {
    let removedItems: [ScannedItem]
    let removedArtifactsCount: Int
    let freedBytes: Int64
    let errors: [String]
}

final class AppUninstallerService {

    // MARK: - Build Deep Uninstall Plan

    static func buildUninstallPlan(for items: [ScannedItem]) async -> AppUninstallPlan {
        await Task.detached(priority: .userInitiated) {
            var allArtifacts: [UninstallArtifact] = []
            var seenPaths = Set<String>()
            var allBundleIDs = Set<String>()
            let fm = FileManager.default

            func addArtifact(
                url: URL,
                kind: LeftoverKind,
                parentAppName: String,
                bundleID: String?,
                precomputedSize: Int64? = nil
            ) {
                let standardized = url.standardizedFileURL.path
                guard !seenPaths.contains(standardized) else { return }
                guard fm.fileExists(atPath: standardized) else { return }
                seenPaths.insert(standardized)

                let size = precomputedSize ?? calculateItemSize(at: url)
                let needsAdmin = requiresAdministrator(at: url)

                let artifact = UninstallArtifact(
                    id: standardized,
                    url: url,
                    name: url.lastPathComponent,
                    kind: kind,
                    sizeBytes: size,
                    parentAppName: parentAppName,
                    bundleIdentifier: bundleID,
                    requiresAdmin: needsAdmin
                )
                allArtifacts.append(artifact)
            }

            for item in items {
                if !item.isApplication {
                    addArtifact(
                        url: item.url,
                        kind: .regularFile,
                        parentAppName: item.name,
                        bundleID: nil,
                        precomputedSize: item.sizeBytes
                    )
                    continue
                }

                let metadata = extractAppMetadata(from: item.url)
                if let bid = metadata.bundleIdentifier, !bid.isEmpty {
                    allBundleIDs.insert(bid)
                }

                // 1. Add the main .app bundle
                addArtifact(
                    url: item.url,
                    kind: .appBundle,
                    parentAppName: item.name,
                    bundleID: metadata.bundleIdentifier,
                    precomputedSize: item.sizeBytes
                )

                // 2. Discover all leftovers in ~/Library, /Library, and /private/var/db/receipts
                let discovered = discoverLeftovers(for: item.url, metadata: metadata)
                for (url, kind) in discovered {
                    addArtifact(
                        url: url,
                        kind: kind,
                        parentAppName: item.name,
                        bundleID: metadata.bundleIdentifier
                    )
                }
            }

            return AppUninstallPlan(
                primaryItems: items,
                artifacts: allArtifacts,
                bundleIdentifiers: allBundleIDs
            )
        }.value
    }

    // MARK: - Execute Deep Uninstall

    @MainActor
    static func executeUninstall(
        plan: AppUninstallPlan,
        mode: UninstallMode
    ) async -> UninstallExecutionResult {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var errors: [String] = []
            var removedArtifactPaths = Set<String>()
            var totalFreedBytes: Int64 = 0

            // 1. Quit running applications matching the plan
            for item in plan.primaryItems where item.isApplication {
                terminateRunningApp(appURL: item.url, bundleIDs: plan.bundleIdentifiers)
            }

            // 2. Clear cfprefsd in-memory preferences & unload user LaunchAgents
            for bundleID in plan.bundleIdentifiers {
                runProcess("/usr/bin/defaults", arguments: ["delete", bundleID])
            }

            for artifact in plan.artifacts where artifact.kind == .launchAgent {
                if artifact.url.path.hasPrefix(NSHomeDirectory()) {
                    let uid = getuid()
                    runProcess("/bin/launchctl", arguments: ["bootout", "gui/\(uid)", artifact.url.path])
                }
            }

            // 3. First pass: try unprivileged removal for user-writable items
            var privilegedQueue: [UninstallArtifact] = []

            for artifact in plan.artifacts {
                // Special handling for ~/Library/Containers/<id>
                if artifact.kind == .container {
                    if removeOrTrashItemUnprivileged(at: artifact.url, mode: mode) {
                        removedArtifactPaths.insert(artifact.id)
                        totalFreedBytes += artifact.sizeBytes
                        continue
                    }
                    // Fallback: clean ~/Library/Containers/<id>/Data (which holds 100% of user data/prefs inside the container)
                    let dataURL = artifact.url.appendingPathComponent("Data", isDirectory: true)
                    if fm.fileExists(atPath: dataURL.path) {
                        if cleanContainerDataDirectory(at: dataURL, appName: artifact.parentAppName, mode: mode) {
                            removedArtifactPaths.insert(artifact.id)
                            totalFreedBytes += artifact.sizeBytes
                            continue
                        }
                    }
                }

                if artifact.requiresAdmin {
                    privilegedQueue.append(artifact)
                    continue
                }

                if removeOrTrashItemUnprivileged(at: artifact.url, mode: mode) {
                    removedArtifactPaths.insert(artifact.id)
                    totalFreedBytes += artifact.sizeBytes
                } else {
                    privilegedQueue.append(artifact)
                }
            }

            // 4. Second pass: handle root-owned / protected items (/Applications/*.app, /Library/*, /private/var/db/receipts/*)
            if !privilegedQueue.isEmpty {
                let (privSucceeded, privErrors) = performPrivilegedRemoval(
                    artifacts: privilegedQueue,
                    bundleIDs: plan.bundleIdentifiers,
                    mode: mode
                )
                for art in privSucceeded {
                    removedArtifactPaths.insert(art.id)
                    totalFreedBytes += art.sizeBytes
                }
                errors.append(contentsOf: privErrors)
            }

            // Determine which primary ScannedItems were successfully removed
            var removedPrimary: [ScannedItem] = []
            for item in plan.primaryItems {
                let stdPath = item.url.standardizedFileURL.path
                if removedArtifactPaths.contains(stdPath) || !fm.fileExists(atPath: stdPath) {
                    removedPrimary.append(item)
                }
            }

            return UninstallExecutionResult(
                removedItems: removedPrimary,
                removedArtifactsCount: removedArtifactPaths.count,
                freedBytes: totalFreedBytes,
                errors: errors
            )
        }.value
    }

    // MARK: - App Metadata Extraction

    private struct AppMetadata {
        let bundleIdentifier: String?
        let candidateNames: [String]
    }

    private static func extractAppMetadata(from appURL: URL) -> AppMetadata {
        let appStem = appURL.deletingPathExtension().lastPathComponent
        var bundleID: String? = nil
        var names: [String] = [appStem]

        // 1. Standard macOS Contents/Info.plist
        let contentsInfo = appURL.appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: contentsInfo) as? [String: Any] {
            if let bid = dict["CFBundleIdentifier"] as? String {
                bundleID = bid
            }
            if let bName = dict["CFBundleName"] as? String {
                names.append(bName)
            }
            if let dName = dict["CFBundleDisplayName"] as? String {
                names.append(dName)
            }
            if let execName = dict["CFBundleExecutable"] as? String {
                names.append(execName)
            }
        }

        // 2. Apple Silicon iOS/iPadOS WrappedBundle/Info.plist
        if bundleID == nil {
            let wrappedInfo = appURL.appendingPathComponent("WrappedBundle/Info.plist")
            if let dict = NSDictionary(contentsOf: wrappedInfo) as? [String: Any] {
                if let bid = dict["CFBundleIdentifier"] as? String {
                    bundleID = bid
                }
                if let bName = dict["CFBundleName"] as? String {
                    names.append(bName)
                }
                if let dName = dict["CFBundleDisplayName"] as? String {
                    names.append(dName)
                }
            }
        }

        // 3. Wrapper/iTunesMetadata.plist fallback
        if bundleID == nil {
            let itunesMeta = appURL.appendingPathComponent("Wrapper/iTunesMetadata.plist")
            if let dict = NSDictionary(contentsOf: itunesMeta) as? [String: Any],
               let bid = dict["softwareVersionBundleId"] as? String {
                bundleID = bid
            }
        }

        // Clean and deduplicate candidate names (only >= 3 chars, excluding generic system words)
        let stopWords: Set<String> = ["app", "mac", "macos", "main", "wrapper", "contents", "helper", "launcher", "studio", "creator"]
        var cleanNames: [String] = []
        for raw in names {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            guard !stopWords.contains(trimmed.lowercased()) else { continue }
            if !cleanNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                cleanNames.append(trimmed)
            }
        }

        return AppMetadata(bundleIdentifier: bundleID, candidateNames: cleanNames)
    }

    // MARK: - Leftover Discovery Engine

    private static func discoverLeftovers(for appURL: URL, metadata: AppMetadata) -> [(URL, LeftoverKind)] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let userLib = home.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)
        let receiptsDir = URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true)

        var results: [(URL, LeftoverKind)] = []

        let searchTargets: [(URL, LeftoverKind, Bool)] = [
            // (Directory, Kind, allowNameMatch)
            (userLib.appendingPathComponent("Preferences"), .preferences, false),
            (userLib.appendingPathComponent("Preferences/ByHost"), .preferences, false),
            (userLib.appendingPathComponent("SyncedPreferences"), .preferences, false),
            (userLib.appendingPathComponent("Application Support"), .appSupport, true),
            (userLib.appendingPathComponent("Application Support/CrashReporter"), .logs, true),
            (userLib.appendingPathComponent("Caches"), .caches, true),
            (userLib.appendingPathComponent("Containers"), .container, false),
            (userLib.appendingPathComponent("Group Containers"), .groupContainer, false),
            (userLib.appendingPathComponent("Saved Application State"), .savedState, false),
            (userLib.appendingPathComponent("Application Scripts"), .appScripts, false),
            (userLib.appendingPathComponent("HTTPStorages"), .cookiesWebKit, false),
            (userLib.appendingPathComponent("WebKit"), .cookiesWebKit, false),
            (userLib.appendingPathComponent("Cookies"), .cookiesWebKit, false),
            (userLib.appendingPathComponent("Logs"), .logs, true),
            (userLib.appendingPathComponent("Logs/DiagnosticReports"), .logs, true),
            (userLib.appendingPathComponent("LaunchAgents"), .launchAgent, false),

            // System-wide (/Library)
            (sysLib.appendingPathComponent("Application Support"), .appSupport, true),
            (sysLib.appendingPathComponent("Preferences"), .preferences, false),
            (sysLib.appendingPathComponent("Caches"), .caches, true),
            (sysLib.appendingPathComponent("Logs"), .logs, true),
            (sysLib.appendingPathComponent("LaunchAgents"), .launchAgent, false),
            (sysLib.appendingPathComponent("LaunchDaemons"), .launchAgent, false),
            (sysLib.appendingPathComponent("PrivilegedHelperTools"), .launchAgent, false),

            // Installer Receipts
            (receiptsDir, .receipt, false)
        ]

        let bidLower = metadata.bundleIdentifier?.lowercased()

        for (dirURL, kind, allowNameMatch) in searchTargets {
            guard let entries = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) else {
                continue
            }

            for entryURL in entries {
                let entryName = entryURL.lastPathComponent
                let entryLower = entryName.lowercased()

                var matched = false

                // 1. Match by Bundle Identifier
                if let bid = bidLower, !bid.isEmpty {
                    if entryLower == bid
                        || entryLower == "\(bid).plist"
                        || entryLower == "\(bid).savedstate"
                        || entryLower == "\(bid).binarycookies"
                        || entryLower == "\(bid).bom"
                        || entryLower.hasPrefix("\(bid).")
                    {
                        matched = true
                    } else if kind == .groupContainer && entryLower.contains(bid) {
                        matched = true
                    } else if kind == .container {
                        // Check com.apple.containermanager.identifier extended attribute for UUID container folders
                        if let xattrBid = readExtendedAttribute(at: entryURL, name: "com.apple.containermanager.identifier")?.lowercased() {
                            if xattrBid == bid || xattrBid.hasPrefix("\(bid).") {
                                matched = true
                            }
                        }
                    }
                }

                // 2. Match by Application Name in supported folders (Application Support, Caches, Logs)
                if !matched && allowNameMatch {
                    for candidate in metadata.candidateNames {
                        let candLower = candidate.lowercased()
                        if entryLower == candLower
                            || entryLower == "\(candLower).plist"
                            || entryLower == "\(candLower).log"
                            || entryLower.hasPrefix("\(candLower) ")
                            || entryLower.hasPrefix("\(candLower)-")
                            || entryLower.hasPrefix("\(candLower)_")
                        {
                            matched = true
                            break
                        }
                    }
                }

                if matched {
                    results.append((entryURL, kind))
                }
            }
        }

        return results
    }

    // MARK: - Low-Level Helpers

    private static func readExtendedAttribute(at url: URL, name: String) -> String? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let result = getxattr(path, name, &buffer, length, 0, XATTR_NOFOLLOW)
        guard result > 0 else { return nil }
        return String(bytes: buffer, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }

    private static func calculateItemSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]

        if let vals = try? url.resourceValues(forKeys: resourceKeys) {
            if vals.isSymbolicLink == true {
                return 0
            }
            if vals.isRegularFile == true && vals.isDirectory != true {
                return Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
            }
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        while let childURL = enumerator.nextObject() as? URL {
            guard let vals = try? childURL.resourceValues(forKeys: resourceKeys) else { continue }
            if vals.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if vals.isRegularFile == true {
                total += Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
            }
        }
        return total
    }

    private static func requiresAdministrator(at url: URL) -> Bool {
        let fm = FileManager.default
        let path = url.path
        if path.hasPrefix("/Library/") || path.hasPrefix("/private/var/") || path.hasPrefix("/System/") {
            return true
        }
        // Check owner UID on the item itself (e.g. root:wheel apps in /Applications)
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let ownerID = attrs[.ownerAccountID] as? NSNumber,
           ownerID.uint32Value == 0 {
            return true
        }
        return !fm.isWritableFile(atPath: path)
    }

    private static func terminateRunningApp(appURL: URL, bundleIDs: Set<String>) {
        let workspace = NSWorkspace.shared
        let stdAppPath = appURL.standardizedFileURL.path
        for running in workspace.runningApplications {
            var shouldKill = false
            if let bid = running.bundleIdentifier, bundleIDs.contains(bid) {
                shouldKill = true
            } else if let bURL = running.bundleURL, bURL.standardizedFileURL.path == stdAppPath {
                shouldKill = true
            }
            if shouldKill {
                running.terminate()
                usleep(150_000)
                if !running.isTerminated {
                    running.forceTerminate()
                }
            }
        }
    }

    private static func removeOrTrashItemUnprivileged(at url: URL, mode: UninstallMode) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        do {
            switch mode {
            case .moveToTrash:
                var resulting: NSURL? = nil
                try fm.trashItem(at: url, resultingItemURL: &resulting)
            case .permanentDelete:
                try fm.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }

    private static func cleanContainerDataDirectory(at dataURL: URL, appName: String, mode: UninstallMode) -> Bool {
        let fm = FileManager.default
        switch mode {
        case .moveToTrash:
            // Move container's Data directory to ~/.Trash with a descriptive name
            let trashDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
            let stamp = Int(Date().timeIntervalSince1970)
            let destURL = trashDir.appendingPathComponent("\(appName)-ContainerData-\(stamp)")
            do {
                try fm.moveItem(at: dataURL, to: destURL)
                return true
            } catch {
                // If moving Data folder itself failed, remove its unlocked children
                return cleanChildrenOfDirectory(at: dataURL, mode: mode)
            }
        case .permanentDelete:
            do {
                try fm.removeItem(at: dataURL)
                return true
            } catch {
                return cleanChildrenOfDirectory(at: dataURL, mode: mode)
            }
        }
    }

    private static func cleanChildrenOfDirectory(at dirURL: URL, mode: UninstallMode) -> Bool {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        var anyRemoved = false
        for child in children {
            if removeOrTrashItemUnprivileged(at: child, mode: mode) {
                anyRemoved = true
            }
        }
        return anyRemoved
    }

    // MARK: - Privileged Removal (Administrator Prompt + Finder Fallback)

    private static func performPrivilegedRemoval(
        artifacts: [UninstallArtifact],
        bundleIDs: Set<String>,
        mode: UninstallMode
    ) -> (succeeded: [UninstallArtifact], errors: [String]) {
        let fm = FileManager.default
        var succeeded: [UninstallArtifact] = []
        var errors: [String] = []

        // First: for any .app in /Applications when mode == .moveToTrash, try Finder delete first!
        // Why? Because Finder is an Apple platform binary with native AppManagement entitlements
        // and shows the native macOS Touch ID / password dialog for root:wheel apps in /Applications.
        var remainingForAdminShell: [UninstallArtifact] = []

        for artifact in artifacts {
            if mode == .moveToTrash && artifact.kind == .appBundle {
                if deleteViaFinderAppleScript(url: artifact.url) && !fm.fileExists(atPath: artifact.url.path) {
                    succeeded.append(artifact)
                    continue
                }
            }
            remainingForAdminShell.append(artifact)
        }

        guard !remainingForAdminShell.isEmpty else {
            return (succeeded, errors)
        }

        // Build a single consolidated shell script to execute with Administrator privileges
        let uid = getuid()
        let gid = getgid()
        let trashPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash").path
        let timestamp = Int(Date().timeIntervalSince1970)

        var scriptLines: [String] = []

        // Unload any system launch daemons/agents first
        for artifact in remainingForAdminShell where artifact.kind == .launchAgent {
            let escaped = shellEscape(artifact.url.path)
            scriptLines.append("/bin/launchctl bootout system \(escaped) >/dev/null 2>&1 || true")
        }

        // Delete system defaults for bundleIDs
        for bid in bundleIDs {
            let escapedBid = shellEscape(bid)
            scriptLines.append("/usr/bin/defaults delete \(escapedBid) >/dev/null 2>&1 || true")
        }

        for (index, artifact) in remainingForAdminShell.enumerated() {
            let srcEscaped = shellEscape(artifact.url.path)
            switch mode {
            case .moveToTrash:
                let baseName = artifact.url.lastPathComponent
                let safeDest = "\(trashPath)/\(baseName)"
                let fallbackDest = "\(trashPath)/\(baseName)-\(timestamp)-\(index)"
                let safeDestEscaped = shellEscape(safeDest)
                let fallbackDestEscaped = shellEscape(fallbackDest)

                scriptLines.append("""
                if [ -e \(srcEscaped) ]; then
                  if [ ! -e \(safeDestEscaped) ]; then
                    /bin/mv -f \(srcEscaped) \(safeDestEscaped) && /usr/sbin/chown -R \(uid):\(gid) \(safeDestEscaped) || true
                  else
                    /bin/mv -f \(srcEscaped) \(fallbackDestEscaped) && /usr/sbin/chown -R \(uid):\(gid) \(fallbackDestEscaped) || true
                  fi
                fi
                """)
            case .permanentDelete:
                scriptLines.append("/bin/rm -rf \(srcEscaped) || true")
            }
        }

        let fullShellScript = scriptLines.joined(separator: "; ")
        let appleScriptSource = "do shell script \(appleScriptStringLiteral(fullShellScript)) with administrator privileges"

        let (adminOK, adminErr) = runOsascript(source: appleScriptSource)

        if !adminOK, let adminErr = adminErr, adminErr.contains("-128") {
            errors.append("Operação cancelada pelo usuário na janela de senha do Administrador.")
            return (succeeded, errors)
        }

        // Check which items were removed by the admin script, and if any .app still remains, try Finder fallback
        for artifact in remainingForAdminShell {
            if !fm.fileExists(atPath: artifact.url.path) {
                succeeded.append(artifact)
            } else if artifact.kind == .appBundle && deleteViaFinderAppleScript(url: artifact.url) && !fm.fileExists(atPath: artifact.url.path) {
                succeeded.append(artifact)
            } else {
                errors.append("Não foi possível remover \(artifact.name). Verifique em Ajustes do Sistema > Privacidade e Segurança > Gerenciamento de Apps (ou Acesso Total ao Disco) se o Varredor está autorizado.")
            }
        }

        return (succeeded, errors)
    }

    private static func deleteViaFinderAppleScript(url: URL) -> Bool {
        let escapedPath = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder"
            delete POSIX file "\(escapedPath)"
        end tell
        """
        let (ok, _) = runOsascript(source: script)
        return ok
    }

    @discardableResult
    private static func runOsascript(source: String) -> (Bool, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                return (true, nil)
            } else {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (false, msg)
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    private static func shellEscape(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptStringLiteral(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
