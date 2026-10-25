import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var scanner = FileScannerService()

    // Filter & Sort states
    @State private var minDaysInactive: Int = 30
    @State private var selectedCategory: ItemCategory = .all
    @State private var minSizeFilter: MinSizeFilter = .any
    @State private var includeHidden: Bool = false
    @State private var searchText: String = ""
    @State private var sortField: SortField = .size
    @State private var sortAscending: Bool = false

    // Selection & Deep Uninstall states
    @State private var selectedIDs: Set<String> = []
    @State private var activeUninstallPlan: AppUninstallPlan? = nil
    @State private var showUninstallSheet: Bool = false
    @State private var uninstallMode: UninstallMode = .moveToTrash
    @State private var isPreparingUninstall: Bool = false
    @State private var isExecutingUninstall: Bool = false
    @State private var resultBannerMessage: String? = nil
    @State private var resultBannerIsError: Bool = false

    private let dayPresets: [Int] = [0, 15, 30, 60, 90, 180, 365]

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "pt_BR")
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    // Filtered items matching threshold, category, size, and search
    private var itemsMeetingDayAndSizeFilter: [ScannedItem] {
        scanner.scannedItems.filter { item in
            guard item.daysSinceLastUse >= minDaysInactive else { return false }
            guard item.sizeBytes >= minSizeFilter.rawValue else { return false }
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                let query = searchText.lowercased()
                let matchName = item.name.lowercased().contains(query)
                let matchPath = item.displayPath.lowercased().contains(query)
                if !matchName && !matchPath { return false }
            }
            return true
        }
    }

    private var filteredAndSortedItems: [ScannedItem] {
        let base = itemsMeetingDayAndSizeFilter.filter { item in
            if selectedCategory == .all { return true }
            return item.category == selectedCategory
        }

        return base.sorted { a, b in
            let comparison: Bool
            switch sortField {
            case .size:
                if a.sizeBytes != b.sizeBytes {
                    comparison = a.sizeBytes < b.sizeBytes
                } else {
                    comparison = a.daysSinceLastUse < b.daysSinceLastUse
                }
            case .daysInactive:
                if a.daysSinceLastUse != b.daysSinceLastUse {
                    comparison = a.daysSinceLastUse < b.daysSinceLastUse
                } else {
                    comparison = a.sizeBytes < b.sizeBytes
                }
            case .lastUsedDate:
                comparison = a.lastReferenceDate < b.lastReferenceDate
            case .name:
                comparison = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortAscending ? comparison : !comparison
        }
    }

    private var totalInactiveBytes: Int64 {
        filteredAndSortedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var inactiveAppsCount: Int {
        itemsMeetingDayAndSizeFilter.filter { $0.isApplication }.count
    }

    private var inactiveAppsBytes: Int64 {
        itemsMeetingDayAndSizeFilter.filter { $0.isApplication }.reduce(0) { $0 + $1.sizeBytes }
    }

    private var selectedItemsList: [ScannedItem] {
        filteredAndSortedItems.filter { selectedIDs.contains($0.id) }
    }

    private var selectedTotalBytes: Int64 {
        selectedItemsList.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 265, ideal: 285, max: 340)
        } detail: {
            VStack(spacing: 0) {
                summaryHeaderView
                Divider()
                filterToolbarView
                Divider()

                if let banner = resultBannerMessage {
                    statusBannerView(message: banner, isError: resultBannerIsError)
                    Divider()
                }

                mainContentView

                Divider()
                bottomActionBar
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationTitle("Varredor — Arquivos e Programas Inativos")
        .onAppear {
            if scanner.scannedItems.isEmpty && !scanner.isScanning {
                scanner.startScan(includeHidden: includeHidden)
            }
        }
        .sheet(isPresented: $showUninstallSheet) {
            if let plan = activeUninstallPlan {
                UninstallPreviewSheet(
                    plan: plan,
                    mode: $uninstallMode,
                    isExecuting: isExecutingUninstall,
                    onCancel: {
                        showUninstallSheet = false
                        activeUninstallPlan = nil
                    },
                    onConfirm: {
                        confirmAndExecuteUninstall(plan: plan)
                    }
                )
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        List {
            Section("Período de Inatividade") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.orange)
                        Text(minDaysInactive == 0 ? "Todos os itens (0+ dias)" : "Sem abrir há \(minDaysInactive)+ dias")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                        ForEach(dayPresets, id: \.self) { preset in
                            Button {
                                minDaysInactive = preset
                            } label: {
                                Text(preset == 0 ? "Todos" : "\(preset)d")
                                    .font(.caption.weight(minDaysInactive == preset ? .bold : .regular))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(minDaysInactive == preset ? Color.accentColor : Color.secondary.opacity(0.15))
                                    )
                                    .foregroundStyle(minDaysInactive == preset ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Stepper(value: $minDaysInactive, in: 0...3650, step: 5) {
                        Text("Ajuste fino: \(minDaysInactive) dias")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Categorias") {
                ForEach(ItemCategory.allCases) { category in
                    let count = categoryCount(for: category)
                    Button {
                        selectedCategory = category
                    } label: {
                        HStack {
                            Label(category.rawValue, systemImage: category.systemImage)
                                .foregroundStyle(selectedCategory == category ? Color.accentColor : Color.primary)
                                .fontWeight(selectedCategory == category ? .semibold : .regular)
                            Spacer()
                            Text("\(count)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(selectedCategory == category ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
                                )
                                .foregroundStyle(selectedCategory == category ? Color.accentColor : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }

            Section("Locais de Varredura") {
                ForEach(scanner.locations) { loc in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { loc.isEnabled },
                            set: { _ in scanner.toggleLocation(loc) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Label(loc.name, systemImage: loc.icon)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(loc.displayPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Spacer()

                        if loc.isCustom {
                            Button {
                                scanner.removeCustomLocation(loc)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remover pasta personalizada")
                        }
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    promptAddCustomFolder()
                } label: {
                    Label("Adicionar Pasta...", systemImage: "folder.badge.plus")
                        .font(.subheadline)
                }
                .buttonStyle(.link)
                .padding(.top, 4)
            }

            Section("Filtros Avançados") {
                Picker("Tamanho Mínimo", selection: $minSizeFilter) {
                    ForEach(MinSizeFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .font(.subheadline)

                Toggle("Incluir arquivos ocultos", isOn: $includeHidden)
                    .font(.subheadline)
                    .onChange(of: includeHidden) { _, newValue in
                        scanner.startScan(includeHidden: newValue)
                    }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Top Summary Cards

    private var summaryHeaderView: some View {
        HStack(spacing: 14) {
            SummaryCardView(
                title: "Itens Inativos (\(minDaysInactive)+ dias)",
                value: "\(filteredAndSortedItems.count)",
                subtitle: "De \(scanner.scannedItems.count) itens analisados",
                icon: "clock.badge.exclamationmark",
                tint: .orange
            )

            SummaryCardView(
                title: "Espaço Recuperável",
                value: ByteCountFormatter.string(fromByteCount: totalInactiveBytes, countStyle: .file),
                subtitle: "Soma dos itens listados abaixo",
                icon: "internaldrive.fill",
                tint: .blue
            )

            SummaryCardView(
                title: "Programas Sem Uso",
                value: "\(inactiveAppsCount) apps",
                subtitle: ByteCountFormatter.string(fromByteCount: inactiveAppsBytes, countStyle: .file),
                icon: "app.badge.checkmark",
                tint: .purple
            )

            SummaryCardView(
                title: "Selecionados p/ Limpeza",
                value: "\(selectedItemsList.count) itens",
                subtitle: ByteCountFormatter.string(fromByteCount: selectedTotalBytes, countStyle: .file),
                icon: "trash.circle.fill",
                tint: selectedItemsList.isEmpty ? .gray : .red
            )
        }
        .padding(16)
    }

    // MARK: - Filter & Sort Toolbar

    private var filterToolbarView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filtrar por nome do arquivo, app ou pasta...", text: $searchText)
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
            .frame(minWidth: 220, maxWidth: 340)

            Spacer()

            HStack(spacing: 6) {
                Text("Ordenar por:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Ordenar por", selection: $sortField) {
                    ForEach(SortField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .labelsHidden()
                .frame(width: 170)

                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .help(sortAscending ? "Ordem Crescente" : "Ordem Decrescente")
            }

            Divider()
                .frame(height: 20)

            if scanner.isScanning {
                Button(role: .destructive) {
                    scanner.cancelScan()
                } label: {
                    Label("Parar", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    scanner.startScan(includeHidden: includeHidden)
                } label: {
                    Label("Varrer Agora", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var mainContentView: some View {
        if scanner.isScanning {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Analisando arquivos e aplicativos...")
                    .font(.headline)
                Text("\(scanner.scannedCount) itens inspecionados")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(scanner.currentScanningPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let error = scanner.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.headline)
                Button("Tentar Novamente") {
                    scanner.startScan(includeHidden: includeHidden)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredAndSortedItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Nenhum item inativo encontrado para este filtro!")
                    .font(.title3.weight(.semibold))
                Text("Não há arquivos ou aplicativos sem abrir há \(minDaysInactive)+ dias nas pastas e filtros selecionados.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                if minDaysInactive > 0 || selectedCategory != .all || minSizeFilter != .any || !searchText.isEmpty {
                    Button("Redefinir Filtros") {
                        minDaysInactive = 30
                        selectedCategory = .all
                        minSizeFilter = .any
                        searchText = ""
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(filteredAndSortedItems) { item in
                    ScannedItemRow(
                        item: item,
                        isSelected: selectedIDs.contains(item.id),
                        dateFormatter: Self.dateFormatter,
                        onToggleSelect: {
                            toggleSelection(for: item)
                        },
                        onReveal: {
                            scanner.revealInFinder(item)
                        },
                        onOpen: {
                            scanner.openItem(item)
                        },
                        onTrash: {
                            prepareUninstall(for: [item])
                        }
                    )
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Button {
                selectAllFiltered()
            } label: {
                Text("Selecionar Todos (\(filteredAndSortedItems.count))")
            }
            .buttonStyle(.bordered)
            .disabled(filteredAndSortedItems.isEmpty)

            if !selectedIDs.isEmpty {
                Button {
                    selectedIDs.removeAll()
                } label: {
                    Text("Limpar Seleção")
                }
                .buttonStyle(.bordered)
            }

            if let lastDate = scanner.lastScanDate {
                Text("Última varredura: \(Self.dateFormatter.string(from: lastDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                exportToCSV()
            } label: {
                Label("Exportar CSV", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(filteredAndSortedItems.isEmpty)

            Button(role: .destructive) {
                prepareUninstall(for: selectedItemsList)
            } label: {
                let formatted = ByteCountFormatter.string(fromByteCount: selectedTotalBytes, countStyle: .file)
                if isPreparingUninstall {
                    Label("Buscando rastros...", systemImage: "magnifyingglass")
                } else {
                    Label(
                        selectedItemsList.isEmpty
                            ? "Desinstalar / Limpar Selecionados"
                            : "Desinstalar e Limpar \(selectedItemsList.count) (\(formatted))",
                        systemImage: "trash.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedItemsList.isEmpty || isPreparingUninstall)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func statusBannerView(message: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.subheadline)
            Spacer()

            if isError {
                Button("Abrir Ajustes de Permissão") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                resultBannerMessage = nil
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

    private func categoryCount(for category: ItemCategory) -> Int {
        if category == .all {
            return itemsMeetingDayAndSizeFilter.count
        }
        return itemsMeetingDayAndSizeFilter.filter { $0.category == category }.count
    }

    private func toggleSelection(for item: ScannedItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func selectAllFiltered() {
        for item in filteredAndSortedItems {
            selectedIDs.insert(item.id)
        }
    }

    private func prepareUninstall(for items: [ScannedItem]) {
        guard !items.isEmpty else { return }
        isPreparingUninstall = true
        Task {
            let plan = await AppUninstallerService.buildUninstallPlan(for: items)
            self.activeUninstallPlan = plan
            self.isPreparingUninstall = false
            self.showUninstallSheet = true
        }
    }

    private func confirmAndExecuteUninstall(plan: AppUninstallPlan) {
        isExecutingUninstall = true
        let chosenMode = uninstallMode
        Task {
            let outcome = await AppUninstallerService.executeUninstall(plan: plan, mode: chosenMode)
            scanner.removeCompletedItems(outcome.removedItems)
            for item in outcome.removedItems {
                selectedIDs.remove(item.id)
            }
            isExecutingUninstall = false
            showUninstallSheet = false
            activeUninstallPlan = nil

            let freedStr = ByteCountFormatter.string(fromByteCount: outcome.freedBytes, countStyle: .file)

            if outcome.errors.isEmpty {
                resultBannerIsError = false
                resultBannerMessage = "Limpeza completa concluída! \(outcome.removedArtifactsCount) arquivo(s)/rastro(s) removido(s) (\(freedStr) liberados) sem deixar preferências."
            } else {
                resultBannerIsError = true
                let errSummary = outcome.errors.joined(separator: " ")
                resultBannerMessage = "Removidos \(outcome.removedArtifactsCount) itens (\(freedStr)), mas houve pendências: \(errSummary)"
            }
        }
    }

    private func promptAddCustomFolder() {
        let panel = NSOpenPanel()
        panel.title = "Escolher Pasta para Varrer"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                scanner.addCustomLocation(url)
            }
            scanner.startScan(includeHidden: includeHidden)
        }
    }

    private func exportToCSV() {
        let savePanel = NSSavePanel()
        savePanel.title = "Exportar Lista de Arquivos e Programas Inativos"
        savePanel.nameFieldStringValue = "relatorio_inativos_\(minDaysInactive)dias.csv"
        savePanel.allowedContentTypes = [.commaSeparatedText]

        guard savePanel.runModal() == .OK, let targetURL = savePanel.url else { return }

        var lines: [String] = [
            "Nome,Tipo,Categoria,Dias Sem Uso,Tamanho (Bytes),Tamanho Formatado,Ultima Data Referencia,Fonte da Data,Caminho Completo"
        ]

        let isoFormatter = ISO8601DateFormatter()
        for item in filteredAndSortedItems {
            let escapedName = "\"\(item.name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let tipo = item.isApplication ? "Programa (.app)" : "Arquivo"
            let cat = "\"\(item.category.rawValue)\""
            let dateStr = isoFormatter.string(from: item.lastReferenceDate)
            let sourceStr = "\"\(item.dateSource.rawValue)\""
            let escapedPath = "\"\(item.url.path.replacingOccurrences(of: "\"", with: "\"\""))\""
            lines.append("\(escapedName),\(tipo),\(cat),\(item.daysSinceLastUse),\(item.sizeBytes),\"\(item.formattedSize)\",\(dateStr),\(sourceStr),\(escapedPath)")
        }

        let csvString = lines.joined(separator: "\n")
        do {
            try csvString.write(to: targetURL, atomically: true, encoding: .utf8)
            resultBannerIsError = false
            resultBannerMessage = "Relatório CSV exportado com sucesso para \(targetURL.lastPathComponent)."
        } catch {
            resultBannerIsError = true
            resultBannerMessage = "Erro ao exportar CSV: \(error.localizedDescription)"
        }
    }
}

// MARK: - Subviews

struct SummaryCardView: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

struct ScannedItemRow: View {
    let item: ScannedItem
    let isSelected: Bool
    let dateFormatter: DateFormatter
    let onToggleSelect: () -> Void
    let onReveal: () -> Void
    let onOpen: () -> Void
    let onTrash: () -> Void

    private var badgeColor: Color {
        if item.daysSinceLastUse >= 180 {
            return .red
        } else if item.daysSinceLastUse >= 60 {
            return .orange
        } else if item.daysSinceLastUse >= 30 {
            return .yellow
        } else {
            return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelect() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if item.isApplication {
                        Text("PROGRAMA")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.purple.opacity(0.18)))
                            .foregroundStyle(.purple)
                    } else if !item.url.pathExtension.isEmpty {
                        Text(item.url.pathExtension.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(item.dateSource.rawValue): \(dateFormatter.string(from: item.lastReferenceDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Days inactive badge
            Text(item.daysSinceLastUse == 0 ? "Hoje" : "Há \(item.daysSinceLastUse) dias")
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(badgeColor.opacity(0.16))
                )
                .foregroundStyle(badgeColor == .yellow ? .orange : badgeColor)

            // File / Bundle size
            Text(item.formattedSize)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 90, alignment: .trailing)

            // Quick Actions
            HStack(spacing: 4) {
                Button {
                    onReveal()
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("Mostrar no Finder")

                Button {
                    onTrash()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("Desinstalar / Limpar sem deixar rastros")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleSelect()
        }
        .contextMenu {
            Button {
                onReveal()
            } label: {
                Label("Mostrar no Finder", systemImage: "folder")
            }

            Button {
                onOpen()
            } label: {
                Label("Abrir Item", systemImage: "arrow.up.forward.app")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            } label: {
                Label("Copiar Caminho Completo", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                onTrash()
            } label: {
                Label("Desinstalar / Limpar Completo (Sem Rastros)", systemImage: "trash")
            }
        }
    }
}
