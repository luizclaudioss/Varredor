import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ArchiveCompressorView: View {
    @ObservedObject var extractor: ArchiveExtractorService

    @State private var isDropTargeted: Bool = false
    @State private var showPlainPassword: Bool = false

    private var previewOutputFilename: String {
        let base = extractor.compressionOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = base.isEmpty ? "Arquivo_Compactado" : base
        let ext = extractor.compressionFormat.fileExtension
        if effectiveBase.lowercased().hasSuffix("." + ext.lowercased()) {
            return effectiveBase
        }
        return "\(effectiveBase).\(ext)"
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 285, ideal: 315, max: 370)
        } detail: {
            VStack(spacing: 0) {
                if let banner = extractor.compressionBannerMessage {
                    bannerView(message: banner, isError: extractor.compressionBannerIsError)
                    Divider()
                }

                summaryHeaderView
                Divider()
                toolbarView
                Divider()
                mainContentArea
                Divider()
                bottomActionBar
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        List {
            Section {
                Button {
                    promptAddFilesOrFolders()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Adicionar Arquivos ou Pastas...")
                                .font(.subheadline.weight(.semibold))
                            Text("Selecione qualquer arquivo, pasta ou aplicativo")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section("Formato do Arquivo Compactado") {
                Picker("Formato", selection: $extractor.compressionFormat) {
                    ForEach(CompressionFormat.allCases) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .font(.subheadline)

                Text(extractor.compressionFormat.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

                if extractor.compressionFormat != .tar && extractor.compressionFormat != .iso {
                    Picker("Nível de Compressão", selection: $extractor.compressionLevel) {
                        ForEach(CompressionLevel.allCases) { lvl in
                            Text(lvl.rawValue).tag(lvl)
                        }
                    }
                    .font(.subheadline)

                    if extractor.compressionFormat == .zip && extractor.compressionLevel == .ultra {
                        Toggle("Motor LZMA no .zip (Até 35% menor)", isOn: $extractor.useLZMAInZip)
                            .font(.caption)
                        Text(
                            extractor.useLZMAInZip
                                ? "Usa algoritmo LZMA de 64 MB dentro do .zip (requer Varredor ou 7-Zip p/ abrir)."
                                : "Usa Deflate Ultra de 15 passadas (100% compatível com o Finder do Mac e Windows)."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Nome e Destino") {
                if extractor.compressionBatchMode == .singleArchive || extractor.compressionItems.count <= 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nome do arquivo final:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField("Ex: Meus_Arquivos", text: $extractor.compressionOutputName)
                                .textFieldStyle(.roundedBorder)
                            Text(".\(extractor.compressionFormat.fileExtension)")
                                .font(.caption.weight(.bold).monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.15))
                                )
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if extractor.compressionItems.count > 1 {
                    Picker("Modo em Lote", selection: $extractor.compressionBatchMode) {
                        ForEach(CompressionBatchMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .font(.subheadline)
                }

                Picker("Salvar em", selection: $extractor.compressionDestinationMode) {
                    ForEach(ArchiveDestinationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .font(.subheadline)
                .onChange(of: extractor.compressionDestinationMode) { _, newValue in
                    if newValue == .custom && extractor.compressionCustomDestinationURL == nil {
                        promptChooseCustomDestination()
                    }
                }

                if extractor.compressionDestinationMode == .custom {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(extractor.compressionCustomDestinationURL?.path ?? "Nenhuma pasta escolhida")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Escolher...") {
                            promptChooseCustomDestination()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            }

            Section("Segurança e Senha") {
                if extractor.compressionFormat.supportsPasswordOutOfTheBox {
                    Toggle("Proteger com Senha (AES-256)", isOn: $extractor.compressionUsePassword)
                        .font(.subheadline)

                    if extractor.compressionUsePassword {
                        HStack(spacing: 6) {
                            if showPlainPassword {
                                TextField("Digite a senha...", text: $extractor.compressionPassword)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("Digite a senha...", text: $extractor.compressionPassword)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button {
                                showPlainPassword.toggle()
                            } label: {
                                Image(systemName: showPlainPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Text("Criptografia forte AES-256 compatível com macOS, Windows e Linux.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Para proteger com senha, selecione o formato ZIP (.zip) ou Imagem macOS (.dmg).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Opções de Limpeza") {
                Toggle("Ignorar arquivos ocultos do Mac (.DS_Store, __MACOSX)", isOn: $extractor.excludeMacOSMetadata)
                    .font(.subheadline)

                Toggle("Mostrar arquivo no Finder ao concluir", isOn: $extractor.revealAfterCompress)
                    .font(.subheadline)

                Toggle("Mover originais p/ o Lixo após compactar", isOn: $extractor.trashSourceAfterCompress)
                    .font(.subheadline)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Top Summary Cards

    private var summaryHeaderView: some View {
        HStack(spacing: 14) {
            SummaryCardView(
                title: "Itens na Lista",
                value: "\(extractor.compressionItems.count) selecionados",
                subtitle: "\(extractor.totalCompressionFileCount) arquivo(s) no total",
                icon: "doc.on.doc.fill",
                tint: .blue
            )

            SummaryCardView(
                title: "Tamanho Original",
                value: ByteCountFormatter.string(fromByteCount: extractor.totalCompressionInputBytes, countStyle: .file),
                subtitle: "Soma dos arquivos e pastas",
                icon: "internaldrive.fill",
                tint: .purple
            )

            SummaryCardView(
                title: "Formato de Saída",
                value: extractor.compressionFormat.shortBadge,
                subtitle: (extractor.compressionUsePassword && extractor.compressionFormat.supportsPasswordOutOfTheBox)
                    ? "🔒 Com Senha • \(extractor.compressionLevel.rawValue)"
                    : extractor.compressionLevel.rawValue,
                icon: "archivebox.fill",
                tint: .teal
            )

            if let outcome = extractor.lastCompressionOutcome {
                SummaryCardView(
                    title: "Última Compactação",
                    value: ByteCountFormatter.string(fromByteCount: outcome.compressedBytes, countStyle: .file),
                    subtitle: "Economia de \(outcome.savingsPercentText) (\(ByteCountFormatter.string(fromByteCount: outcome.savedBytes, countStyle: .file)))",
                    icon: "checkmark.seal.fill",
                    tint: .green
                )
            } else {
                SummaryCardView(
                    title: "Arquivo de Destino",
                    value: previewOutputFilename,
                    subtitle: extractor.compressionDestinationMode.rawValue,
                    icon: "arrow.down.doc.fill",
                    tint: .orange
                )
            }
        }
        .padding(16)
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 12) {
            Label(
                extractor.compressionItems.isEmpty
                    ? "Adicione arquivos ou pastas para criar seu pacote compactado"
                    : "Itens que serão incluídos em \(previewOutputFilename)",
                systemImage: "tray.full.fill"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)

            Spacer()

            if !extractor.compressionItems.isEmpty {
                Button {
                    extractor.clearCompressionItems()
                } label: {
                    Label("Limpar Lista", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(extractor.isCompressing)
            }

            Button {
                promptAddFilesOrFolders()
            } label: {
                Label("Adicionar Arquivos / Pastas...", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(extractor.isCompressing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var mainContentArea: some View {
        if extractor.isCompressing {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Compactando em \(previewOutputFilename)...")
                    .font(.headline)
                Text(extractor.compressionStepText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if extractor.compressionItems.isEmpty {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 2.5, dash: [10, 6])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                        )
                        .frame(maxWidth: 640, maxHeight: 350)

                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                            .font(.system(size: 62))
                            .foregroundStyle(Color.accentColor)

                        Text("Arraste arquivos e pastas aqui para compactar")
                            .font(.title2.weight(.bold))

                        Text("Crie arquivos .zip (com senha AES-256), .7z, .tar.xz, .tar.gz, .tar.bz2, .iso ou .dmg com 1 clique.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)

                        HStack(spacing: 8) {
                            ForEach(CompressionFormat.allCases) { fmt in
                                Button {
                                    extractor.compressionFormat = fmt
                                } label: {
                                    Text(fmt.shortBadge)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(
                                                    extractor.compressionFormat == fmt
                                                        ? Color.accentColor
                                                        : Color.accentColor.opacity(0.14)
                                                )
                                        )
                                        .foregroundStyle(
                                            extractor.compressionFormat == fmt ? Color.white : Color.accentColor
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)

                        Button {
                            promptAddFilesOrFolders()
                        } label: {
                            Label("Escolher Arquivos ou Pastas...", systemImage: "folder.badge.plus")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            List {
                ForEach(extractor.compressionItems) { item in
                    HStack(spacing: 12) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)

                                if item.isDirectory {
                                    Text("PASTA (\(item.itemCount) arq.)")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.blue.opacity(0.16)))
                                        .foregroundStyle(.blue)
                                } else if !item.url.pathExtension.isEmpty {
                                    Text(item.url.pathExtension.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(item.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(item.formattedSize)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .frame(width: 95, alignment: .trailing)

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: {
                            Image(systemName: "folder")
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .help("Mostrar no Finder")

                        Button {
                            extractor.removeCompressionItem(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .help("Remover da lista")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            if let outcome = extractor.lastCompressionOutcome,
               let firstURL = outcome.createdURLs.first {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(outcome.createdURLs)
                } label: {
                    Label("Mostrar no Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    extractor.openArchivesFromFinder(outcome.createdURLs, autoSwitchModule: true)
                } label: {
                    Label("Inspecionar Arquivo Criado (\(firstURL.lastPathComponent))", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button {
                Task {
                    await extractor.createArchive()
                }
            } label: {
                if extractor.compressionBatchMode == .separateArchives && extractor.compressionItems.count > 1 {
                    Label(
                        "Compactar \(extractor.compressionItems.count) Arquivos (.\(extractor.compressionFormat.fileExtension))",
                        systemImage: "archivebox.fill"
                    )
                } else {
                    Label(
                        "Compactar Agora (\(previewOutputFilename))",
                        systemImage: "archivebox.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(extractor.compressionItems.isEmpty || extractor.isCompressing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func bannerView(message: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button {
                extractor.compressionBannerMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isError ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
    }

    // MARK: - Helpers

    private func promptAddFilesOrFolders() {
        let panel = NSOpenPanel()
        panel.title = "Escolher Arquivos ou Pastas para Compactar"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            extractor.addCompressionItems(panel.urls)
        }
    }

    private func promptChooseCustomDestination() {
        let panel = NSOpenPanel()
        panel.title = "Escolher Pasta onde o Arquivo Compactado será Salvo"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            extractor.compressionCustomDestinationURL = url
            extractor.compressionDestinationMode = .custom
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                found = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var resolvedURL: URL?
                    if let data = item as? Data {
                        resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        resolvedURL = url
                    }
                    if let finalURL = resolvedURL {
                        Task { @MainActor in
                            extractor.addCompressionItems([finalURL])
                        }
                    }
                }
            }
        }
        return found
    }
}
