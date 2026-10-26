import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ArchiveUnpackerView: View {
    @ObservedObject var extractor: ArchiveExtractorService

    @State private var searchText: String = ""
    @State private var entrySortField: EntrySortField = .path
    @State private var entrySortAscending: Bool = true
    @State private var hideDirectoriesInList: Bool = false
    @State private var selectedEntryIDs: Set<String> = []
    @State private var isDropTargeted: Bool = false

    private var currentJob: ArchiveJobItem? {
        extractor.selectedJob
    }

    private var filteredEntries: [ArchiveEntry] {
        guard let job = currentJob else { return [] }
        let base = job.entries.filter { entry in
            if hideDirectoriesInList && entry.isDirectory { return false }
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                let q = searchText.lowercased()
                return entry.name.lowercased().contains(q) || entry.relativePath.lowercased().contains(q)
            }
            return true
        }

        return base.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            let cmp: Bool
            switch entrySortField {
            case .path:
                cmp = a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
            case .size:
                if a.uncompressedSize != b.uncompressedSize {
                    cmp = a.uncompressedSize < b.uncompressedSize
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            case .type:
                if a.fileExtension != b.fileExtension {
                    cmp = a.fileExtension < b.fileExtension
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            return entrySortAscending ? cmp : !cmp
        }
    }

    private var selectedEntriesBytes: Int64 {
        guard let job = currentJob else { return 0 }
        return job.entries
            .filter { selectedEntryIDs.contains($0.id) && !$0.isDirectory }
            .reduce(0) { $0 + $1.uncompressedSize }
    }

    private var pendingJobsCount: Int {
        extractor.jobs.filter { !$0.status.isCompleted }.count
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 280, ideal: 305, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let banner = extractor.bannerMessage {
                    bannerView(message: banner, isError: extractor.bannerIsError)
                    Divider()
                }

                if let job = currentJob {
                    jobSummaryHeader(for: job)
                    Divider()
                    inspectorToolbar(for: job)
                    Divider()
                    inspectorContentArea(for: job)
                    Divider()
                    bottomActionBar(for: job)
                } else {
                    emptyDropStateView
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onChange(of: extractor.selectedJobID) { _, _ in
            selectedEntryIDs.removeAll()
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
        .sheet(isPresented: $extractor.showPasswordSheet) {
            if let promptID = extractor.passwordPromptJobID,
               let job = extractor.jobs.first(where: { $0.id == promptID }) {
                ArchivePasswordSheet(
                    job: job,
                    initialPassword: job.password ?? extractor.defaultPassword,
                    onCancel: {
                        extractor.showPasswordSheet = false
                        extractor.passwordPromptJobID = nil
                    },
                    onConfirm: { password, applyAll in
                        extractor.supplyPassword(password, applyToAll: applyAll, forJobID: job.id)
                    }
                )
            }
        }
    }

    // MARK: - Sidebar (Queue & Settings)

    private var sidebarView: some View {
        List {
            Section {
                Button {
                    promptOpenArchiveFiles()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Adicionar Arquivos...")
                                .font(.subheadline.weight(.semibold))
                            Text(".zip, .rar, .7z, .iso, .tar, .gz, .bz2, .xz, .dmg")
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

            Section {
                if extractor.jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nenhum arquivo na fila")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Arraste arquivos compactados para a janela ou dê duplo clique neles no Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(extractor.jobs) { job in
                        ArchiveQueueRow(
                            job: job,
                            isSelected: extractor.selectedJob?.id == job.id,
                            onSelect: {
                                extractor.selectedJobID = job.id
                            },
                            onExtractNow: {
                                Task {
                                    await extractor.extractArchive(jobID: job.id, selectedEntryIDs: nil)
                                }
                            },
                            onRemove: {
                                extractor.removeJob(job.id)
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Fila de Arquivos (\(extractor.jobs.count))")
                    Spacer()
                    if !extractor.jobs.isEmpty {
                        Button("Limpar") {
                            extractor.clearAllJobs()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            }

            Section("Destino da Extração") {
                Picker("Salvar em", selection: $extractor.destinationMode) {
                    ForEach(ArchiveDestinationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .font(.subheadline)
                .onChange(of: extractor.destinationMode) { _, newValue in
                    if newValue == .custom && extractor.customDestinationURL == nil {
                        promptChooseCustomDestination()
                    }
                }

                if extractor.destinationMode == .custom {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(extractor.customDestinationURL?.path ?? "Nenhuma pasta escolhida")
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

                Toggle("Criar subpasta com o nome do arquivo", isOn: $extractor.createSubfolder)
                    .font(.subheadline)

                Picker("Se já existir", selection: $extractor.overwritePolicy) {
                    ForEach(ArchiveOverwritePolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .font(.subheadline)
            }

            Section("Automação e Pós-Extração") {
                Toggle("Extrair automaticamente ao soltar/abrir", isOn: $extractor.autoExtractOnAdd)
                    .font(.subheadline)

                Toggle("Mostrar pasta no Finder ao concluir", isOn: $extractor.revealInFinderAfterExtract)
                    .font(.subheadline)

                Toggle("Mover compactado p/ o Lixo após extrair", isOn: $extractor.trashArchiveAfterExtract)
                    .font(.subheadline)
            }

            Section("Senha Padrão (Lote)") {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("Senha opcional p/ arquivos protegidos", text: $extractor.defaultPassword)
                        .textFieldStyle(.roundedBorder)
                    Text("Usada automaticamente caso o arquivo exija senha.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section("Motores Ativos no Sistema") {
                Text(extractor.availableEnginesSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Empty Drop Zone View

    private var emptyDropStateView: some View {
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
                    .frame(maxWidth: 640, maxHeight: 360)

                VStack(spacing: 16) {
                    Image(systemName: "archivebox.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.accentColor)

                    Text("Arraste seus arquivos compactados aqui")
                        .font(.title2.weight(.bold))

                    Text("Inspecione o conteúdo antes de extrair ou descompacte lotes inteiros com 1 clique.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)

                    // Format pills
                    HStack(spacing: 8) {
                        ForEach(["ZIP", "RAR", "7Z", "ISO", "DMG", "TAR.GZ", "TAR.XZ", "BZ2", "GZ"], id: \.self) { fmt in
                            Text(fmt)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.14))
                                )
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Button {
                            promptOpenArchiveFiles()
                        } label: {
                            Label("Selecionar Arquivos Compactados...", systemImage: "folder.badge.plus")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Job Summary Header

    private func jobSummaryHeader(for job: ArchiveJobItem) -> some View {
        HStack(spacing: 14) {
            SummaryCardView(
                title: "Formato & Motor",
                value: job.format.rawValue,
                subtitle: job.isEncrypted ? "🔒 Protegido • \(job.engineUsed)" : "🔓 Sem senha • \(job.engineUsed)",
                icon: job.isEncrypted ? "lock.doc.fill" : "archivebox.fill",
                tint: job.isEncrypted ? .orange : .blue
            )

            SummaryCardView(
                title: "Tamanho Compactado",
                value: job.formattedCompressedSize,
                subtitle: "Descompactado: \(job.formattedUncompressedSize)",
                icon: "arrow.up.left.and.arrow.down.right.circle.fill",
                tint: .teal
            )

            SummaryCardView(
                title: "Conteúdo Interno",
                value: "\(job.fileCount) arquivos",
                subtitle: "\(job.folderCount) pastas • \(job.compressionRatioText)",
                icon: "doc.on.doc.fill",
                tint: .purple
            )

            SummaryCardView(
                title: selectedEntryIDs.isEmpty ? "Modo de Extração" : "Itens Selecionados",
                value: selectedEntryIDs.isEmpty ? "Extrair Tudo" : "\(selectedEntryIDs.count) marcados",
                subtitle: selectedEntryIDs.isEmpty
                    ? "Total: \(job.formattedUncompressedSize)"
                    : ByteCountFormatter.string(fromByteCount: selectedEntriesBytes, countStyle: .file),
                icon: selectedEntryIDs.isEmpty ? "tray.and.arrow.down.fill" : "checkmark.circle.fill",
                tint: selectedEntryIDs.isEmpty ? .green : .orange
            )
        }
        .padding(16)
    }

    // MARK: - Inspector Toolbar

    private func inspectorToolbar(for job: ArchiveJobItem) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Buscar arquivo dentro de \(job.name)...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            )
            .frame(minWidth: 220, maxWidth: 320)

            Toggle("Ocultar pastas", isOn: $hideDirectoriesInList)
                .font(.subheadline)
                .toggleStyle(.checkbox)

            Spacer()

            HStack(spacing: 6) {
                Text("Ordenar:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Ordenar", selection: $entrySortField) {
                    ForEach(EntrySortField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .labelsHidden()
                .frame(width: 145)

                Button {
                    entrySortAscending.toggle()
                } label: {
                    Image(systemName: entrySortAscending ? "arrow.up" : "arrow.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
            }

            Divider()
                .frame(height: 20)

            Button {
                promptOpenArchiveFiles()
            } label: {
                Label("Adicionar Mais", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Inspector Content Area

    @ViewBuilder
    private func inspectorContentArea(for job: ArchiveJobItem) -> some View {
        switch job.status {
        case .inspecting, .queued:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Lendo estrutura interna de \(job.name)...")
                    .font(.headline)
                Text("Identificando arquivos, pastas e compressão")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .extracting(_, let step):
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Descompactando \(job.name)...")
                    .font(.headline)
                Text(step)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .passwordRequired(let msg):
            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.orange)
                Text("Arquivo Protegido por Senha")
                    .font(.title3.weight(.bold))
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                Button {
                    extractor.passwordPromptJobID = job.id
                    extractor.showPasswordSheet = true
                } label: {
                    Label("Digitar Senha para Desbloquear...", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let err):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("Não foi possível ler ou extrair \(job.name)")
                    .font(.title3.weight(.semibold))
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                HStack(spacing: 12) {
                    Button {
                        extractor.passwordPromptJobID = job.id
                        extractor.showPasswordSheet = true
                    } label: {
                        Label("Tentar com Senha", systemImage: "key.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            await extractor.inspectArchive(jobID: job.id)
                        }
                    } label: {
                        Label("Tentar Novamente", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready, .completed:
            if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(job.entries.isEmpty ? "Este arquivo não listou itens internos (pronto para extração direta)." : "Nenhum item corresponde à busca.")
                        .font(.headline)
                    if !searchText.isEmpty {
                        Button("Limpar Busca") {
                            searchText = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        ArchiveEntryRow(
                            entry: entry,
                            isSelected: selectedEntryIDs.contains(entry.id),
                            onToggleSelect: {
                                toggleEntrySelection(entry)
                            },
                            onQuickPreview: {
                                extractor.quickPreviewEntry(entry, in: job)
                            },
                            onExtractSingle: {
                                Task {
                                    await extractor.extractArchive(jobID: job.id, selectedEntryIDs: [entry.id])
                                }
                            }
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Bottom Action Bar

    private func bottomActionBar(for job: ArchiveJobItem) -> some View {
        HStack(spacing: 12) {
            Button {
                for entry in filteredEntries {
                    selectedEntryIDs.insert(entry.id)
                }
            } label: {
                Text("Selecionar Todos (\(filteredEntries.count))")
            }
            .buttonStyle(.bordered)
            .disabled(filteredEntries.isEmpty)

            if !selectedEntryIDs.isEmpty {
                Button {
                    selectedEntryIDs.removeAll()
                } label: {
                    Text("Limpar Seleção")
                }
                .buttonStyle(.bordered)
            }

            Button {
                extractor.passwordPromptJobID = job.id
                extractor.showPasswordSheet = true
            } label: {
                Label(job.password == nil ? "Definir Senha" : "Senha Configurada ✓", systemImage: "key.fill")
            }
            .buttonStyle(.bordered)

            if let outURL = job.lastOutputURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                } label: {
                    Label("Mostrar Extraídos no Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if extractor.jobs.count > 1 && pendingJobsCount > 0 {
                Button {
                    Task {
                        await extractor.extractAllQueued()
                    }
                } label: {
                    Label("Extrair Fila (\(pendingJobsCount))", systemImage: "square.stack.3d.down.right.fill")
                }
                .buttonStyle(.bordered)
                .disabled(extractor.isBatchExtracting || job.status.isBusy)
            }

            if !selectedEntryIDs.isEmpty {
                Button {
                    Task {
                        await extractor.extractArchive(jobID: job.id, selectedEntryIDs: selectedEntryIDs)
                    }
                } label: {
                    Label("Extrair Selecionados (\(selectedEntryIDs.count))", systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(job.status.isBusy)
            }

            Button {
                Task {
                    await extractor.extractArchive(jobID: job.id, selectedEntryIDs: nil)
                }
            } label: {
                Label("Extrair Tudo de \(job.name)", systemImage: "archivebox.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(job.status.isBusy)
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
                extractor.bannerMessage = nil
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

    // MARK: - Actions & Helpers

    private func toggleEntrySelection(_ entry: ArchiveEntry) {
        if selectedEntryIDs.contains(entry.id) {
            selectedEntryIDs.remove(entry.id)
        } else {
            selectedEntryIDs.insert(entry.id)
        }
    }

    private func promptOpenArchiveFiles() {
        let panel = NSOpenPanel()
        panel.title = "Escolher Arquivos Compactados (.zip, .rar, .7z, .iso, .tar, .gz, .bz2, .xz, .dmg)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            extractor.addArchives(panel.urls)
        }
    }

    private func promptChooseCustomDestination() {
        let panel = NSOpenPanel()
        panel.title = "Escolher Pasta de Destino para Descompactação"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            extractor.customDestinationURL = url
            extractor.destinationMode = .custom
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
                            var isDir: ObjCBool = false
                            let exists = FileManager.default.fileExists(atPath: finalURL.path, isDirectory: &isDir)
                            if exists && (isDir.boolValue || !ArchiveFormat.isSupportedArchive(finalURL)) {
                                extractor.openItemsForCompression([finalURL], autoSwitchModule: true)
                            } else {
                                extractor.addArchives([finalURL])
                            }
                        }
                    }
                }
            }
        }
        return found
    }
}

// MARK: - Subviews

private struct ArchiveQueueRow: View {
    let job: ArchiveJobItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onExtractNow: () -> Void
    let onRemove: () -> Void

    private var statusColor: Color {
        switch job.status {
        case .queued, .inspecting:
            return .secondary
        case .ready:
            return .blue
        case .passwordRequired:
            return .orange
        case .extracting:
            return .purple
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.format.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)

                    if job.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Text(job.name)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 6) {
                    Text(job.formattedCompressedSize)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(job.status.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if !job.status.isBusy && !job.status.isCompleted {
                Button {
                    onExtractNow()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Extrair agora")
            }

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remover da fila")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

private struct ArchiveEntryRow: View {
    let entry: ArchiveEntry
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onQuickPreview: () -> Void
    let onExtractSingle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelect() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(nsImage: entry.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if entry.isDirectory {
                        Text("PASTA")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    } else if !entry.fileExtension.isEmpty {
                        Text(entry.fileExtension.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(entry.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(entry.permissions)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            Text(entry.formattedSize)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 90, alignment: .trailing)

            HStack(spacing: 6) {
                if !entry.isDirectory {
                    Button {
                        onQuickPreview()
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Visualizar este arquivo rapidamente")
                }

                Button {
                    onExtractSingle()
                } label: {
                    Image(systemName: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Extrair somente este item")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ArchivePasswordSheet: View {
    let job: ArchiveJobItem
    let initialPassword: String
    let onCancel: () -> Void
    let onConfirm: (String, Bool) -> Void

    @State private var password: String = ""
    @State private var showPlainPassword: Bool = false
    @State private var applyToAllInQueue: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.doc.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Senha do Arquivo Compactado")
                        .font(.title3.weight(.bold))
                    Text(job.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            Text("Digite a senha necessária para listar ou descompactar os arquivos deste pacote.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if showPlainPassword {
                    TextField("Senha do arquivo...", text: $password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("Senha do arquivo...", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    showPlainPassword.toggle()
                } label: {
                    Image(systemName: showPlainPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .help(showPlainPassword ? "Ocultar senha" : "Mostrar senha")
            }

            Toggle("Usar esta mesma senha para os demais arquivos da fila", isOn: $applyToAllInQueue)
                .font(.subheadline)

            HStack {
                Spacer()
                Button("Cancelar") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Desbloquear e Extrair") {
                    onConfirm(password, applyToAllInQueue)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(password.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            password = initialPassword
        }
    }
}
