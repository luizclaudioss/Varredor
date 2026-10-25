import SwiftUI
import AppKit

struct UninstallPreviewSheet: View {
    let plan: AppUninstallPlan
    @Binding var mode: UninstallMode
    let isExecuting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var hasAdminItems: Bool {
        plan.artifacts.contains { $0.requiresAdmin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 14) {
                Image(systemName: "trash.slash.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Desinstalação e Limpeza Completa (Zero Rastros)")
                        .font(.title3.weight(.bold))

                    Text("Todos os pacotes, preferências (.plist), caches, containers, estados salvos e registros (receipts) serão removidos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(18)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Summary Pills
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Itens Principais")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(plan.primaryItems.count)")
                        .font(.headline.monospacedDigit())
                }

                Divider().frame(height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rastros e Preferências Detectados")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("+\(plan.leftoversCount) itens (\(plan.formattedLeftoversSize))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                }

                Divider().frame(height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Espaço Total Liberado")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(plan.formattedTotalSize)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.red)
                }

                Spacer()

                if hasAdminItems {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.blue)
                        Text("Solicitará senha/Touch ID do Mac")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.12))
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            // List of all artifacts to be cleaned
            List {
                if !plan.bundleIdentifiers.isEmpty {
                    Section("Limpeza de Memória de Preferências (cfprefsd)") {
                        ForEach(Array(plan.bundleIdentifiers).sorted(), id: \.self) { bid in
                            HStack(spacing: 8) {
                                Image(systemName: "memorychip")
                                    .foregroundStyle(.purple)
                                Text("defaults delete \(bid)")
                                    .font(.caption.monospaced())
                                Spacer()
                                Text("Cache de Preferências da RAM")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Arquivos, Pacotes e Rastros no Disco (\(plan.artifacts.count))") {
                    ForEach(plan.artifacts) { artifact in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: artifact.url.path))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(artifact.name)
                                        .font(.subheadline.weight(artifact.kind == .appBundle ? .semibold : .regular))
                                        .lineLimit(1)

                                    Text(artifact.kind.rawValue)
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            Capsule().fill(badgeColor(for: artifact.kind).opacity(0.16))
                                        )
                                        .foregroundStyle(badgeColor(for: artifact.kind))

                                    if artifact.requiresAdmin {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .help("Item protegido por root — será removido com permissão de Administrador")
                                    }
                                }

                                Text(artifact.displayPath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Text(artifact.formattedSize)
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            // Footer Controls
            HStack(spacing: 14) {
                Picker("Modo de Remoção:", selection: $mode) {
                    ForEach(UninstallMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 340)
                .disabled(isExecuting)

                Spacer()

                if isExecuting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Removendo app e todos os rastros...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Cancelar", role: .cancel) {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(role: .destructive) {
                        onConfirm()
                    } label: {
                        Label(
                            mode == .moveToTrash
                                ? "Limpar Tudo p/ Lixeira (\(plan.formattedTotalSize))"
                                : "Excluir Tudo Permanentemente (\(plan.formattedTotalSize))",
                            systemImage: "trash.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 740, idealWidth: 780, minHeight: 500, idealHeight: 560)
    }

    private func badgeColor(for kind: LeftoverKind) -> Color {
        switch kind {
        case .appBundle: return .purple
        case .preferences: return .orange
        case .container, .groupContainer: return .blue
        case .appSupport: return .teal
        case .caches: return .pink
        case .receipt: return .red
        default: return .secondary
        }
    }
}
