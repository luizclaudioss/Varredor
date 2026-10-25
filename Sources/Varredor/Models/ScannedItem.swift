import Foundation
import AppKit

enum ItemCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "Todos"
    case application = "Programas (.app)"
    case document = "Documentos"
    case archive = "Instaladores e Compactados"
    case media = "Mídia (Vídeo/Áudio/Imagem)"
    case other = "Outros Arquivos"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "tray.full.fill"
        case .application: return "app.badge.checkmark"
        case .document: return "doc.text.fill"
        case .archive: return "shippingbox.fill"
        case .media: return "photo.on.rectangle.angled"
        case .other: return "doc.fill"
        }
    }

    static func categorize(url: URL, isApplication: Bool) -> ItemCategory {
        if isApplication {
            return .application
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "pages", "numbers", "key", "csv", "epub":
            return .document
        case "dmg", "pkg", "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso":
            return .archive
        case "mp4", "mov", "mkv", "avi", "mp3", "wav", "aac", "flac", "m4a", "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "psd", "ai", "raw":
            return .media
        default:
            return .other
        }
    }
}

enum SortField: String, CaseIterable, Identifiable {
    case size = "Tamanho"
    case daysInactive = "Dias sem uso"
    case lastUsedDate = "Data do último acesso"
    case name = "Nome"

    var id: String { rawValue }
}

enum MinSizeFilter: Int64, CaseIterable, Identifiable {
    case any = 0
    case oneMB = 1_000_000
    case tenMB = 10_000_000
    case fiftyMB = 50_000_000
    case hundredMB = 100_000_000
    case fiveHundredMB = 500_000_000

    var id: Int64 { rawValue }

    var label: String {
        switch self {
        case .any: return "Qualquer tamanho"
        case .oneMB: return "Maior que 1 MB"
        case .tenMB: return "Maior que 10 MB"
        case .fiftyMB: return "Maior que 50 MB"
        case .hundredMB: return "Maior que 100 MB"
        case .fiveHundredMB: return "Maior que 500 MB"
        }
    }
}

struct ScanLocation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: URL
    let icon: String
    var isEnabled: Bool
    let isCustom: Bool

    var displayPath: String {
        path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

enum DateSourceKind: String, Sendable {
    case spotlightLastUsed = "Última abertura (macOS)"
    case neverOpenedInstalled = "Nunca aberto (data de instalação/criação)"
    case fileSystemAccess = "Último acesso/modificação"
}

struct ScannedItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isApplication: Bool
    let category: ItemCategory
    let sizeBytes: Int64
    let lastReferenceDate: Date
    let lastOpenedDate: Date?
    let modificationDate: Date?
    let creationDate: Date?
    let dateSource: DateSourceKind
    let daysSinceLastUse: Int

    var displayPath: String {
        url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
