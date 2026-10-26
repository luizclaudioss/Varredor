import Foundation
import AppKit
import UniformTypeIdentifiers

enum AppModule: String, CaseIterable, Identifiable {
    case cleaner = "Limpeza"
    case unpacker = "Descompactar"
    case compressor = "Compactar"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cleaner: return "paintbrush.pointed.fill"
        case .unpacker: return "archivebox.fill"
        case .compressor: return "arrow.down.right.and.arrow.up.left.circle.fill"
        }
    }
}

enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip = "ZIP"
    case rar = "RAR"
    case sevenZip = "7Z"
    case iso = "ISO"
    case dmg = "DMG"
    case tar = "TAR"
    case tarGz = "TAR.GZ"
    case tarBz2 = "TAR.BZ2"
    case tarXz = "TAR.XZ"
    case tarZst = "TAR.ZST"
    case gzip = "GZ"
    case bzip2 = "BZ2"
    case xz = "XZ"
    case zst = "ZST"
    case xar = "XAR / PKG"
    case cab = "CAB"
    case cpio = "CPIO"
    case deb = "DEB"
    case rpm = "RPM"
    case other = "ARQUIVO"

    var id: String { rawValue }

    var badgeColorName: String {
        switch self {
        case .zip: return "blue"
        case .rar: return "purple"
        case .sevenZip: return "indigo"
        case .iso, .dmg: return "orange"
        case .tar, .tarGz, .tarBz2, .tarXz, .tarZst: return "teal"
        case .gzip, .bzip2, .xz, .zst: return "cyan"
        case .xar, .cab, .cpio, .deb, .rpm, .other: return "gray"
        }
    }

    var isSingleStreamCompression: Bool {
        switch self {
        case .gzip, .bzip2, .xz, .zst:
            return true
        default:
            return false
        }
    }

    var isDiskImage: Bool {
        switch self {
        case .iso, .dmg:
            return true
        default:
            return false
        }
    }

    static let supportedExtensions: Set<String> = [
        "zip", "cbz", "jar", "war", "ipa", "apk",
        "rar", "cbr",
        "7z", "cb7",
        "iso", "cdr", "dmg", "img",
        "tar", "tgz", "tbz", "tbz2", "txz", "tlz", "tzst",
        "gz", "bz2", "xz", "zst",
        "xar", "pkg", "cab", "cpio", "deb", "rpm", "lha", "lzh"
    ]

    static func detect(from url: URL) -> ArchiveFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .tarGz
        } else if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") {
            return .tarBz2
        } else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") || name.hasSuffix(".tar.lzma") || name.hasSuffix(".tlz") {
            return .tarXz
        } else if name.hasSuffix(".tar.zst") || name.hasSuffix(".tzst") {
            return .tarZst
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip", "cbz", "jar", "war", "ipa", "apk":
            return .zip
        case "rar", "cbr":
            return .rar
        case "7z", "cb7":
            return .sevenZip
        case "iso", "cdr", "img":
            return .iso
        case "dmg":
            return .dmg
        case "tar":
            return .tar
        case "gz":
            return .gzip
        case "bz2":
            return .bzip2
        case "xz":
            return .xz
        case "zst":
            return .zst
        case "xar", "pkg":
            return .xar
        case "cab":
            return .cab
        case "cpio":
            return .cpio
        case "deb":
            return .deb
        case "rpm":
            return .rpm
        default:
            return .other
        }
    }

    static func isSupportedArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar.zst") {
            return true
        }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Returns the base name of the archive stripping compound extensions like .tar.gz
    static func baseArchiveName(for url: URL) -> String {
        let filename = url.lastPathComponent
        let lower = filename.lowercased()
        let compoundSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma", ".tar.z"]
        for suffix in compoundSuffixes {
            if lower.hasSuffix(suffix) {
                return String(filename.dropLast(suffix.count))
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

struct ArchiveEntry: Identifiable, Hashable, Sendable {
    let id: String              // Relative path inside archive
    let relativePath: String    // Full relative path inside archive
    let name: String            // Last path component
    let parentFolder: String    // Parent folder inside archive
    let isDirectory: Bool
    let uncompressedSize: Int64
    let modificationDate: Date?
    let permissions: String

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var formattedSize: String {
        if isDirectory { return "Pasta" }
        return ByteCountFormatter.string(fromByteCount: uncompressedSize, countStyle: .file)
    }

    var icon: NSImage {
        if isDirectory {
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Pasta")
                ?? NSWorkspace.shared.icon(for: .folder)
        }
        let ext = fileExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

enum ArchiveJobStatus: Equatable, Sendable {
    case queued
    case inspecting
    case ready
    case passwordRequired(String)
    case extracting(progress: Double, currentStep: String)
    case completed(destinationURL: URL, extractedCount: Int)
    case failed(String)

    var label: String {
        switch self {
        case .queued:
            return "Na fila"
        case .inspecting:
            return "Lendo estrutura..."
        case .ready:
            return "Pronto p/ extrair"
        case .passwordRequired:
            return "Senha necessária"
        case .extracting(_, let step):
            return step.isEmpty ? "Extraindo..." : step
        case .completed(_, let count):
            return "Extraído (\(count) \(count == 1 ? "item" : "itens"))"
        case .failed(let msg):
            return "Erro: \(msg)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .inspecting, .extracting:
            return true
        default:
            return false
        }
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var needsPassword: Bool {
        if case .passwordRequired = self { return true }
        return false
    }
}

enum ArchiveDestinationMode: String, CaseIterable, Identifiable {
    case sameAsArchive = "Mesma pasta do arquivo original"
    case downloads = "Pasta Downloads"
    case desktop = "Pasta Mesa (Desktop)"
    case custom = "Pasta personalizada..."

    var id: String { rawValue }
}

enum ArchiveOverwritePolicy: String, CaseIterable, Identifiable {
    case overwrite = "Sobrescrever arquivos existentes"
    case skipExisting = "Manter existentes (não sobrescrever)"

    var id: String { rawValue }
}

struct ArchiveJobItem: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let format: ArchiveFormat
    let compressedSizeBytes: Int64
    let modificationDate: Date?

    var entries: [ArchiveEntry] = []
    var status: ArchiveJobStatus = .queued
    var isEncrypted: Bool = false
    var password: String? = nil
    var engineUsed: String = "libarchive (bsdtar)"
    var lastOutputURL: URL? = nil

    var formattedCompressedSize: String {
        ByteCountFormatter.string(fromByteCount: compressedSizeBytes, countStyle: .file)
    }

    var totalUncompressedBytes: Int64 {
        entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.uncompressedSize }
    }

    var formattedUncompressedSize: String {
        let total = totalUncompressedBytes
        if total <= 0 { return "—" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var fileCount: Int {
        entries.filter { !$0.isDirectory }.count
    }

    var folderCount: Int {
        entries.filter { $0.isDirectory }.count
    }

    var compressionRatioText: String {
        let uncompressed = Double(totalUncompressedBytes)
        let compressed = Double(compressedSizeBytes)
        guard uncompressed > 0, compressed > 0, uncompressed >= compressed else { return "—" }
        let saved = (1.0 - (compressed / uncompressed)) * 100.0
        return String(format: "%.0f%% menor", saved)
    }
}

enum EntrySortField: String, CaseIterable, Identifiable {
    case path = "Caminho / Nome"
    case size = "Tamanho"
    case type = "Tipo"

    var id: String { rawValue }
}

// MARK: - Compression (Create Archive) Models

enum CompressionFormat: String, CaseIterable, Identifiable, Sendable {
    case sevenZip = "7-Zip Sólido (.7z)"
    case tarXz = "TAR.XZ Ultra (.tar.xz)"
    case tarZst = "Zstandard (.tar.zst)"
    case zip = "ZIP Universal (.zip)"
    case dmg = "Imagem macOS (.dmg)"
    case tarGz = "TAR.GZ (.tar.gz)"
    case tarBz2 = "TAR.BZ2 (.tar.bz2)"
    case tar = "TAR (.tar)"
    case iso = "ISO 9660 (.iso)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tarXz: return "tar.xz"
        case .tarZst: return "tar.zst"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tar: return "tar"
        case .iso: return "iso"
        case .dmg: return "dmg"
        }
    }

    var shortBadge: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7Z"
        case .tarXz: return "TAR.XZ"
        case .tarZst: return "TAR.ZST"
        case .tarGz: return "TAR.GZ"
        case .tarBz2: return "TAR.BZ2"
        case .tar: return "TAR"
        case .iso: return "ISO"
        case .dmg: return "DMG"
        }
    }

    var subtitle: String {
        switch self {
        case .sevenZip:
            return "🔥 Campeão de redução • Bloco Sólido LZMA2 (Dicionário 128 MB) + Senha AES-256"
        case .tarXz:
            return "🔥 Compressão Extrema LZMA2 (Preset 9e + Dicionário 128 MB + Filtro ARM64)"
        case .tarZst:
            return "⚡ Zstandard Nível 22 Ultra (Janela 128 MB) • Altíssima redução e descompressão veloz"
        case .zip:
            return "Compatibilidade universal • Modo Ultra com 15 passadas (ou motor LZMA) + Senha AES-256"
        case .dmg:
            return "Imagem de disco macOS com compressão LZMA (ULMO) • Até 35% menor que DMG padrão"
        case .tarGz:
            return "Rápido e universal para sistemas UNIX/Linux/macOS (GZip Nível 9)"
        case .tarBz2:
            return "Compressão BZip2 em blocos de 900 KB"
        case .tar:
            return "Agrupamento instantâneo sem compressão"
        case .iso:
            return "Imagem de disco óptica universal ISO-9660"
        }
    }

    var supportsPasswordOutOfTheBox: Bool {
        switch self {
        case .zip, .dmg, .sevenZip:
            return true
        default:
            return false
        }
    }
}

enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case store = "Apenas Armazenar (Instantâneo)"
    case fast = "Rápido (Menor uso de CPU)"
    case normal = "Equilibrado"
    case maximum = "Máximo (Nível 9)"
    case ultra = "🔥 Ultra / Extrema (Máxima Redução)"

    var id: String { rawValue }

    var numericLevel: Int {
        switch self {
        case .store: return 0
        case .fast: return 1
        case .normal: return 6
        case .maximum: return 9
        case .ultra: return 9
        }
    }
}

enum CompressionBatchMode: String, CaseIterable, Identifiable, Sendable {
    case singleArchive = "Juntar tudo em um único arquivo compactado"
    case separateArchives = "Criar um arquivo separado para cada item da lista"

    var id: String { rawValue }
}

struct CompressionSourceItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    var sizeBytes: Int64
    var itemCount: Int // 1 for file, or recursive count for folder

    var displayPath: String {
        url.deletingLastPathComponent().path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct CompressionOutcome: Sendable {
    let createdURLs: [URL]
    let originalBytes: Int64
    let compressedBytes: Int64

    var savedBytes: Int64 {
        max(0, originalBytes - compressedBytes)
    }

    var savingsPercentText: String {
        guard originalBytes > 0, compressedBytes > 0, originalBytes >= compressedBytes else {
            return "0%"
        }
        let pct = (1.0 - (Double(compressedBytes) / Double(originalBytes))) * 100.0
        return String(format: "%.1f%%", pct)
    }
}

