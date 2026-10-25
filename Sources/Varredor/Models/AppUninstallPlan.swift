import Foundation

enum LeftoverKind: String, CaseIterable, Sendable {
    case appBundle = "Aplicativo Principal (.app)"
    case regularFile = "Arquivo"
    case preferences = "Preferências (.plist)"
    case container = "Container Sandbox"
    case groupContainer = "Group Container"
    case appSupport = "Suporte do Aplicativo (Application Support)"
    case caches = "Cache"
    case savedState = "Estado Salvo da Janela"
    case launchAgent = "Agente/Daemon de Inicialização"
    case appScripts = "Scripts do Aplicativo"
    case cookiesWebKit = "Dados WebKit / HTTP / Cookies"
    case logs = "Logs e Relatórios"
    case receipt = "Registro de Instalação (Receipt)"

    var icon: String {
        switch self {
        case .appBundle: return "app.badge.checkmark"
        case .regularFile: return "doc.fill"
        case .preferences: return "slider.horizontal.3"
        case .container, .groupContainer: return "shippingbox.and.arrow.backward.fill"
        case .appSupport: return "folder.fill.badge.gearshape"
        case .caches: return "bolt.horizontal.circle.fill"
        case .savedState: return "macwindow"
        case .launchAgent: return "gearshape.2.fill"
        case .appScripts: return "applescript.fill"
        case .cookiesWebKit: return "globe"
        case .logs: return "doc.text.magnifyingglass"
        case .receipt: return "Burst"
        }
    }
}

struct UninstallArtifact: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: LeftoverKind
    let sizeBytes: Int64
    let parentAppName: String
    let bundleIdentifier: String?
    let requiresAdmin: Bool

    var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct AppUninstallPlan: Sendable {
    let primaryItems: [ScannedItem]
    let artifacts: [UninstallArtifact]
    let bundleIdentifiers: Set<String>

    var totalSizeBytes: Int64 {
        artifacts.reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    var leftoversCount: Int {
        artifacts.filter { $0.kind != .appBundle && $0.kind != .regularFile }.count
    }

    var leftoversSizeBytes: Int64 {
        artifacts
            .filter { $0.kind != .appBundle && $0.kind != .regularFile }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedLeftoversSize: String {
        ByteCountFormatter.string(fromByteCount: leftoversSizeBytes, countStyle: .file)
    }
}
