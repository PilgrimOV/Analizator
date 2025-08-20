import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Основной интерфейс
struct ContentView: View {
    @StateObject private var model = AnalyzerModel()
    enum Tab { case analysis, normalization }
    @State private var selectedTab: Tab = .analysis
    @State private var sortDescriptor = AnalysisTableView.SortDescriptor(column: .file, ascending: true)
    
    private var selectedRootFolder: URL? { model.commonParent(of: model.selectedFiles) }
    
    var body: some View {
        HStack(spacing: 0) {
            // ===== Sidebar =====
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 22))
                    Text("Analizator").font(.title2).fontWeight(.semibold)
                }
                .padding(.top, 6)
                
                Divider().padding(.bottom, 2)
                
                Button { selectFilesOrFolder() } label: {
                    Label("Выбрать файлы или папку", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    addAllFromCurrentFolder()
                } label: {
                    Label("Добавить все файлы из папки", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.bordered)
                .disabled(selectedRootFolder == nil)
                
                // Строка "Выбрано файлов" + бейдж папки
                VStack(alignment: .leading, spacing: 6) {
                    Text("Выбрано файлов: \(model.selectedFiles.count)")
                        .font(.callout).foregroundStyle(.secondary)
                    
                    if let root = selectedRootFolder {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "folder.fill").foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(root.lastPathComponent).font(.callout).bold()
                                Text(model.displayPath(for: root))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 6)
                            Button { model.revealInFinder(root) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless).help("Показать в Finder")
                        }
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                
                if model.isAnalyzing {
                    ProgressView(value: Double(model.progressDone),
                                 total: Double(max(model.selectedFiles.count, 1))) {
                        Text("Анализ…")
                    } currentValueLabel: {
                        Text("\(model.progressDone)/\(model.selectedFiles.count)")
                    }
                }
                
                HStack {
                    Button {
                        selectedTab = .analysis        // 👈 переключаемся на вкладку Анализ
                        model.analyzeAllFiles()
                    } label: {
                        Label("Анализировать", systemImage: "play.fill")
                    }
                    .disabled(model.isAnalyzing || model.selectedFiles.isEmpty || model.ffmpegOK == false)
                    
                    Button("🔍 Проверить данные") {
                        Swift.print("=== ДИАГНОСТИКА ДАННЫХ ===")
                        Swift.print("selectedFiles.count: \(model.selectedFiles.count)")
                        Swift.print("analysisResults.count: \(model.analysisResults.count)")
                        for (i, r) in model.analysisResults.enumerated() {
                            Swift.print("[\(i)] \(r.fileURL.lastPathComponent)")
                            Swift.print("    LUFS: '\(r.lufs ?? "NIL")'")
                            Swift.print("    TP:   '\(r.truePeak ?? "NIL")'")
                            Swift.print("    LRA:  '\(r.lra ?? "NIL")'")
                            Swift.print("    SR:   '\(r.sampleRate ?? "NIL")'")
                            Swift.print("    Status: \(r.status)")
                        }
                        Swift.print("=== КОНЕЦ ДИАГНОСТИКИ ===")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.analysisResults.isEmpty)
                    
                    Button { model.stopAnalyzing = true } label: {
                        Label("Остановить", systemImage: "stop.fill")
                    }
                    .disabled(!model.isAnalyzing)
                }
                .buttonStyle(.bordered)
                
                Button(role: .destructive) { model.clearList() } label: {
                    Label("Очистить список", systemImage: "trash")
                }
                .disabled(model.isAnalyzing || model.selectedFiles.isEmpty)
                .buttonStyle(.bordered)
                
                Divider().padding(.vertical, 2)
                
                // Нормализация + Стоп (НЕ ТРОГАЛ)
                HStack {
                    Button {
                        selectedTab = .normalization   // 👈 переключаемся на вкладку Нормализация
                        model.runNormalization(selectedRootFolder: selectedRootFolder)
                    } label: {
                        Label("Нормализовать", systemImage: "dial.max.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isNormalizing || selectedRootFolder == nil || model.ffmpegOK == false)

                    Button { model.stopNormalization() } label: {
                        Label("Стоп", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.bordered).disabled(!model.isNormalizing)
                }
                
                // Переименование файлов в выбранной папке
                Button {
                    renameAllInSelectedFolder()
                } label: {
                    Label("Переименовать все файлы в папке", systemImage: "textformat.alt")
                }
                .buttonStyle(.bordered)
                .disabled(selectedRootFolder == nil || model.isAnalyzing || model.isNormalizing)
                .help("Переименовать файлы в «\(selectedRootFolder?.lastPathComponent ?? "…")» как Аудио_1, Аудио_2, …")
                
                // Удаление «старых» файлов без суффикса _New из выбранной папки (только текущая папка)
                Button {
                    deleteOldFilesInSelectedFolder()
                } label: {
                    Label("Удалить старые файлы", systemImage: "trash.slash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(selectedRootFolder == nil || model.isAnalyzing || model.isNormalizing)
                .help("Отправить в корзину все файлы БЕЗ суффикса _New в «\(selectedRootFolder?.lastPathComponent ?? "…")». Работает только в этой папке, без подпапок.")
                
                if let ffmpegOK = model.ffmpegOK, ffmpegOK == false {
                    ffmpegNotFoundView
                }
                
                Spacer()
                
                // Легенда
                VStack(alignment: .leading, spacing: 6) {
                    Text("Критерии статуса:").font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 8) { statusDot(.gray);  Text("Неизвестно (ещё не анализировалось)").font(.footnote) }
                    HStack(spacing: 8) {
                        statusDot(.green)
                        Text("LUFS \(Settings.okLUFSRange.lowerBound)…\(Settings.okLUFSRange.upperBound), TP ≤ \(Settings.okTruePeakMax), SR 44.1/48 kHz").font(.footnote)
                    }
                    HStack(spacing: 8) { statusDot(.red);   Text("Иначе — предупреждение").font(.footnote) }
                }
                .padding(.bottom, 6)
            }
            .frame(width: 300)
            .padding(14)
            .background(.regularMaterial)
            
            Divider()
            
            // ===== Main panel =====
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Анализ").tag(Tab.analysis)
                    Text("Нормализация").tag(Tab.normalization)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                Divider()
                
                if selectedTab == .analysis {
                    Text("rows: \(model.analysisResults.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    AnalysisTableView(
                        results: sortedResultsForTable(),
                        sortDescriptor: sortDescriptor,
                        onSortChange: { sortDescriptor = $0 }
                    )
                    .background(Color(nsColor: .windowBackgroundColor))
                } else {
                    NormalizationLogView(log: model.normalizationLog, isProcessing: model.isNormalizing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
        }
        .frame(minWidth: 1024, minHeight: 600)
        .onAppear { model.ffmpegOK = model.isFFmpegInstalled() }
    }
    
    // MARK: - Вспомогательные View
    private func statusDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
    
    private var ffmpegNotFoundView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text("FFmpeg не найден").bold()
            }
            Text("Установите через Homebrew:")
                .font(.footnote).foregroundStyle(.secondary)
            Text("brew install ffmpeg")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Табличные данные (сортировка)
    private func sortedResultsForTable() -> [AudioAnalysisResult] {
        Swift.print("📊 Сортируем таблицу. Всего результатов: \(model.analysisResults.count)")
        var list = model.analysisResults
        switch sortDescriptor.column {
        case .status:
            list.sort { sortDescriptor.ascending ? $0.statusPriority < $1.statusPriority : $0.statusPriority > $1.statusPriority }
        case .file:
            list.sort {
                let a = $0.fileURL.lastPathComponent
                let b = $1.fileURL.lastPathComponent
                return sortDescriptor.ascending
                    ? a.localizedCompare(b) == .orderedAscending
                    : a.localizedCompare(b) == .orderedDescending
            }
        case .lufs:
            list.sort {
                let a = Double($0.lufs ?? "") ?? .infinity
                let b = Double($1.lufs ?? "") ?? .infinity
                return sortDescriptor.ascending ? a < b : a > b
            }
        case .tp:
            list.sort {
                let a = Double($0.truePeak ?? "") ?? .infinity
                let b = Double($1.truePeak ?? "") ?? .infinity
                return sortDescriptor.ascending ? a < b : a > b
            }
        case .lra:
            list.sort {
                let a = Double($0.lra ?? "") ?? .infinity
                let b = Double($1.lra ?? "") ?? .infinity
                return sortDescriptor.ascending ? a < b : a > b
            }
        case .sr:
            list.sort {
                let numA = Int(($0.sampleRate ?? "").replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 0
                let numB = Int(($1.sampleRate ?? "").replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 0
                return sortDescriptor.ascending ? numA < numB : numB < numA
            }
        }
        Swift.print("✅ Таблица отсортирована")
        return list
    }
    
    // MARK: - DnD и выбор
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var allNewFiles: [URL] = []
        
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, _) in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                model.collectFiles(from: url, into: &allNewFiles)
            }
        }
        group.notify(queue: .main) { appendSelected(files: allNewFiles) }
        return true
    }
    
    private func selectFilesOrFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK {
            var files: [URL] = []
            for url in panel.urls { model.collectFiles(from: url, into: &files) }
            appendSelected(files: files)
        }
    }
    
    private func appendSelected(files: [URL]) {
        let filtered = files.filter { model.allowedExtensions.contains($0.pathExtension.lowercased()) }
        for url in filtered {
            let u = url.standardizedFileURL.resolvingSymlinksInPath()
            if !model.selectedFiles.map({ $0.path }).contains(u.path) {
                model.selectedFiles.append(u)
                model.analysisResults.append(AudioAnalysisResult(
                    fileURL: u, lufs: nil, lra: nil, truePeak: nil, sampleRate: nil, status: .unknown
                ))
            }
        }
        Swift.print("[UPDATE] Добавили файлов: \(filtered.count). Всего: \(model.selectedFiles.count)")
    }
    
    private func addAllFromCurrentFolder() {
        guard let root = selectedRootFolder else { return }
        var files: [URL] = []
        model.collectFiles(from: root, into: &files)   // рекурсивно собираем все аудиофайлы
        appendSelected(files: files)                   // добавляем только недостающие
    }
    
    // ⬇️ Переименовать все файлы в выбранной папке (только верхний уровень папки)
    private func renameAllInSelectedFolder() {
        guard let root = selectedRootFolder else { return }

        // Работаем в фоне, чтобы не подвисал UI
        DispatchQueue.global(qos: .userInitiated).async {
            let renamed = FileOps.renameAllInSelectedFolder(root: root, allowedExtensions: model.allowedExtensions)

            // Обновляем данные в модели одним махом — уже на главном потоке
            DispatchQueue.main.async {
                guard !renamed.isEmpty else { return }

                // 1) Заменим пути в selectedFiles
                for (old, new) in renamed {
                    if let i = model.selectedFiles.firstIndex(where: {
                        $0.standardizedFileURL.resolvingSymlinksInPath().path ==
                        old.standardizedFileURL.resolvingSymlinksInPath().path
                    }) {
                        model.selectedFiles[i] = new
                    }
                }

                // 2) Заменим fileURL в analysisResults (пересоберём элемент — fileURL у структуры 'let')
                for (old, new) in renamed {
                    if let j = model.analysisResults.firstIndex(where: { $0.fileURL.path == old.path }) {
                        let r = model.analysisResults[j]
                        model.analysisResults[j] = AudioAnalysisResult(
                            fileURL: new,
                            lufs: r.lufs, lra: r.lra, truePeak: r.truePeak,
                            sampleRate: r.sampleRate, status: r.status
                        )
                    }
                }

                Swift.print("[RENAME] Переименовано файлов:", renamed.count)
            }
        }
    }
    
    // ⬇️ Удалить (в корзину) все файлы БЕЗ суффикса _New в выбранной папке (не рекурсивно)
    private func deleteOldFilesInSelectedFolder() {
        guard let root = selectedRootFolder else { return }

        // Работаем в фоне, чтобы не подвисал UI
        DispatchQueue.global(qos: .userInitiated).async {
            let trashed = FileOps.deleteOldFilesInSelectedFolder(root: root, allowedExtensions: model.allowedExtensions)

            // Обновляем данные модели на главном потоке
            DispatchQueue.main.async {
                guard !trashed.isEmpty else { return }

                // Удаляем удалённые файлы из selectedFiles
                model.selectedFiles.removeAll { u in
                    let p = u.standardizedFileURL.resolvingSymlinksInPath().path
                    return trashed.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == p }
                }

                // И из analysisResults
                model.analysisResults.removeAll { r in
                    let p = r.fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                    return trashed.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == p }
                }

                Swift.print("[TRASH] В корзину отправлено:", trashed.count)
            }
        }
    }
}
