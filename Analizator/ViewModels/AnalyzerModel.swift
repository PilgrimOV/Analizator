//
//  AnalyzerModel.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation
import SwiftUI

// MARK: - ViewModel как в "old"-духе: публикуем готовые снимки
@MainActor
final class AnalyzerModel: ObservableObject {
    // UI-состояние
    @Published var selectedFiles: [URL] = []
    @Published var analysisResults: [AudioAnalysisResult] = []      // длина/порядок = selectedFiles
    @Published var isAnalyzing = false
    @Published var stopAnalyzing = false
    @Published var ffmpegOK: Bool? = nil
    
    // прогресс
    @Published var progressDone: Int = 0
    
    // Нормализация — НЕ ТРОГАЛ
    @Published var normalizationLog: String = ""
    @Published var isNormalizing = false
    @Published var normalizationProcess: Process?
    @Published var normalizingCurrent: URL?
    @Published var normalizedDone: Set<URL> = []
    @Published var normalizationSectionIndex: Int = 0   // нумерация «Обработка файла: …»
    @Published var normalizationCreatedCount: Int = 0   // сколько реально создано файлов
    @Published var lastNormalizationRoot: URL? = nil
    
    let allowedExtensions = ["mp3", "m4a", "mp4"]
    
    // MARK: - Вспомогательные
    func isFFmpegInstalled() -> Bool { 
        FFmpegLocator.isFFmpegInstalled() 
    }
    
    func resolvedFFmpegPath() -> String? {
        FFmpegLocator.resolvedFFmpegPath()
    }
    
    func revealInFinder(_ url: URL) { 
        FileOps.revealInFinder(url) 
    }
    
    func displayPath(for url: URL) -> String {
        FileOps.displayPath(for: url)
    }
    
    func commonParent(of urls: [URL]) -> URL? {
        FileOps.commonParent(of: urls)
    }
    
    func collectFiles(from url: URL, into result: inout [URL]) {
        FileOps.collectFiles(from: url, into: &result, allowedExtensions: allowedExtensions)
    }
    
    func clearList() {
        selectedFiles.removeAll()
        analysisResults.removeAll()
        normalizingCurrent = nil
        normalizedDone.removeAll()
        normalizationSectionIndex = 0
        normalizationCreatedCount = 0
        normalizationLog = ""
        progressDone = 0
        Swift.print("[UPDATE] Очистили список.")
    }
    
    // MARK: - АНАЛИЗ (как в рабочей версии: публикуем снимки массива)
    func analyzeAllFiles() {
        guard !selectedFiles.isEmpty else { return }
        isAnalyzing = true
        stopAnalyzing = false
        progressDone = 0
        
        let files = selectedFiles.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        Swift.print("[ANALYZE] Старт. Файлов:", files.count)
        
        // Готовим "болванки", чтобы строки сразу появились
        var tempResults: [AudioAnalysisResult] = files.map {
            AudioAnalysisResult(fileURL: $0, lufs: nil, lra: nil, truePeak: nil, sampleRate: nil, status: .unknown)
        }
        self.analysisResults = tempResults
        
        let indexByPath = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($0.element.path, $0.offset) })
        let concurrency = min(8, max(1, ProcessInfo.processInfo.processorCount - 1))
        Swift.print("[ANALYZE] Пул потоков:", concurrency)
        
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: concurrency)
        let updateQueue = DispatchQueue(label: "analysis.update.queue") // синхронизация tempResults
        
        for file in files {
            if stopAnalyzing { break }
            semaphore.wait()
            group.enter()
            
            DispatchQueue.global(qos: .userInitiated).async {
                defer { semaphore.signal(); group.leave() }
                
                Swift.print("[ANALYZE] ▶︎ \(file.lastPathComponent)")
                guard let res = LoudnessAnalyzer.analyzeFile(url: file) else {
                    Swift.print("[ANALYZE] ✖︎ \(file.lastPathComponent) (нет результата)")
                    Task { @MainActor in self.progressDone += 1 }
                    return
                }
                
                // Пишем в tempResults под своим индексом
                updateQueue.sync {
                    if let idx = indexByPath[file.path], idx < tempResults.count {
                        tempResults[idx] = res
                        Swift.print("[UPDATE] tempResults[\(idx)] ← \(file.lastPathComponent)")
                    }
                }
                
                // Публикуем СНИМОК целиком (как делала старая рабочая версия)
                Task { @MainActor in
                    self.analysisResults = tempResults
                    self.progressDone += 1
                    Swift.print("[UPDATE] analysisResults ⇐ tempResults (rows: \(self.analysisResults.count))")
                }
            }
        }
        
        group.notify(queue: .main) {
            self.analysisResults = tempResults // финальный снимок
            self.isAnalyzing = false
            self.stopAnalyzing = false
            Swift.print("[ANALYZE] Готово. Всего строк:", self.analysisResults.count)
        }
    }
    
    // =============== НОРМАЛИЗАЦИЯ — ПЕРЕНЕСЕНО БЕЗ ИЗМЕНЕНИЙ ===============
    func runNormalization(selectedRootFolder: URL?) {
        normalizationLog = ""
        isNormalizing = true
        normalizingCurrent = nil
        normalizedDone.removeAll()
        normalizationSectionIndex = 0
        normalizationCreatedCount = 0
        
        guard let scriptPath = Bundle.main.path(forResource: "Normal", ofType: "sh") else {
            normalizationLog = "❌ Скрипт Normal.sh не найден в бандле."
            isNormalizing = false
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        
        guard let workDir = (selectedRootFolder ?? lastNormalizationRoot ?? selectedFiles.first?.deletingLastPathComponent()) else {
            normalizationLog = "❌ Не выбрана папка для нормализации."
            isNormalizing = false
            return
        }
        lastNormalizationRoot = workDir
        
        let p = Process()
        p.currentDirectoryPath = workDir.path
        p.launchPath = "/bin/bash"
        p.arguments = [scriptPath, workDir.path]
        normalizationProcess = p
        
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var lineRemainder = ""   // локальный буфер незавершённой строки для ЭТОГО запуска
        
        // Живой лог: фильтрация от мусора + трекинг текущего файла
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // строка-кусок из пайпа
            var chunk = String(data: data, encoding: .utf8) ?? ""

            // 1) чистим ANSI
            chunk = chunk.replacingOccurrences(of: #"\u001B\[[0-9;]*m"#,
                                               with: "", options: .regularExpression)
            chunk = chunk.replacingOccurrences(of: "\r", with: "")
            
            // 2) добавляем «хвост» от прошлого чтения и режем на строки
            chunk = lineRemainder + chunk
            var lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            // если последняя строка без \n — оставляем как хвост на следующий раз
            if let last = lines.last, !chunk.hasSuffix("\n") {
                lineRemainder = last
                lines.removeLast()
            } else {
                lineRemainder = ""
            }

            // 3) обрабатываем только ЦЕЛЫЕ строки
            let fullText = lines.joined(separator: "\n")
            if fullText.isEmpty { return }

            let filtered = self.filterNormalizationChunk(fullText)
            if filtered.isEmpty { return }

            // строгое упорядочивание: одна последовательная очередь + sync на Main
            DispatchQueue.main.async {
                let numbered = self.addSectionNumbers(to: filtered)
                self.normalizationLog.append(numbered + "\n")
                self.trackNormalizationProgress(from: numbered, workDir: workDir)
            }
        }
        
        p.terminationHandler = { _ in
            // 1) перестаём читать новые чанки
            pipe.fileHandleForReading.readabilityHandler = nil

            // 2) дочитываем конец пайпа
            let restData = pipe.fileHandleForReading.readDataToEndOfFile()
            let restStr = String(data: restData, encoding: .utf8) ?? ""

            // 3) объединяем с недочитанной строкой (если была)
            var tail = lineRemainder + restStr
            lineRemainder = ""

            // 4) чистим ANSI и режем только на целые строки
            tail = tail.replacingOccurrences(of: #"\u001B\[[0-9;]*m"#, with: "", options: .regularExpression)
            tail = tail.replacingOccurrences(of: "\r", with: "")
            var lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let last = lines.last, !tail.hasSuffix("\n") {
                // на всякий случай — не должно оставаться, но не теряем
                lineRemainder = last
                lines.removeLast()
            }
            let tailText = lines.joined(separator: "\n")

            DispatchQueue.main.async {
                if !tailText.isEmpty {
                    let filtered = self.filterNormalizationChunk(tailText)
                    if !filtered.isEmpty {
                        let numberedTail = self.addSectionNumbers(to: filtered)
                        self.normalizationLog.append(numberedTail + "\n")
                    }
                }

                // 5) финальный ИТОГ — строго в самом конце, с отступом
                if !self.normalizationLog.hasSuffix("\n\n") { self.normalizationLog.append("\n") }
                let summary = "ИТОГ: обработано файлов: \(self.normalizationSectionIndex), создано новых файлов: \(self.normalizationCreatedCount)\n"
                self.normalizationLog.append(summary)

                self.isNormalizing = false
                self.normalizationProcess = nil
                self.normalizingCurrent = nil
            }
        }

        do { try p.run() }
        catch {
            normalizationLog = "❌ Не удалось запустить скрипт: \(error.localizedDescription)"
            isNormalizing = false
            normalizationProcess = nil
        }
    }
    
    func addSectionNumbers(to text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []

        for raw in lines {
            // сохраняем пустые строки без дублей
            if raw.isEmpty {
                if out.last?.isEmpty != true { out.append("") }
                continue
            }

            let line = raw.trimmingCharacters(in: .whitespaces)

            // финальные сообщения — отделяем пустой строкой сверху
            if line.localizedCaseInsensitiveContains("обработка всех файлов завершена успешно")
                || line.localizedCaseInsensitiveContains("обработка завершена с ошибками") {
                if out.last?.isEmpty != true { out.append("") }
                out.append(line)
                continue
            }

            // блоки «Обработка файла …» — нумерация + разделитель
            if line.localizedCaseInsensitiveContains("обработка файла") {
                normalizationSectionIndex += 1
                if normalizationSectionIndex > 1, out.last?.isEmpty != true {
                    out.append("") // пустая строка между блоками файлов
                }
                out.append("\(normalizationSectionIndex) — \(line)")
            } else {
                out.append(line)
            }
        }

        return out.joined(separator: "\n")
    }
    
    func stopNormalization() {
        normalizationProcess?.interrupt()   // SIGINT
        normalizationProcess?.terminate()   // SIGTERM
        isNormalizing = false
    }
    
    nonisolated func filterNormalizationChunk(_ chunk: String) -> String {
        // убираем ANSI-коды
        let stripped = chunk.replacingOccurrences(
            of: #"\u001B\[[0-9;]*m"#,
            with: "",
            options: .regularExpression
        )

        let keepEmojiPrefixes = ["✅","⚠️","❌","🎵","🔍","🟡","🗂️","📦"]
        let keepContains = [
            "Обработка завершена с ошибками",
            "Обработка всех файлов завершена успешно"
        ]

        let lines = stripped
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard !line.isEmpty else { return nil }

                if keepEmojiPrefixes.contains(where: { line.hasPrefix($0) }) { return line }
                // "Обработка файла" может идти после эмодзи/номера — ловим по вхождению, без учёта регистра
                // если есть любой префикс (мусор/проценты/символы), отрезаем всё слева до маркера
                if let r = line.range(of: #"обработка файла\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                    let filePart = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    // Сохраним исходную лупу, если была; иначе добавим 🔍
                    let lens = line.contains("🔎") ? "🔎" : (line.contains("🔍") ? "🔍" : "🔍")
                    return "\(lens) Обработка файла: \(filePart)"
                }
                if keepContains.contains(where: { line.contains($0) }) { return line }

                return nil
            }

        return lines.joined(separator: "\n")
    }
    
    func trackNormalizationProgress(from chunk: String, workDir: URL) {
        let lines = chunk.split(separator: "\n").map(String.init)
        for line in lines {
            if let path = extractPath(after: "Обработка файла:", from: line) {
                let url = resolveLogPath(path, relativeTo: workDir)
                normalizingCurrent = url
            } else if line.localizedCaseInsensitiveContains("создан новый файл")
                     || line.localizedCaseInsensitiveContains("пропускаем:")
                     || line.contains("✅") {
                if let cur = normalizingCurrent { normalizedDone.insert(cur) }
                if line.localizedCaseInsensitiveContains("создан новый файл") {
                    normalizationCreatedCount += 1
                }
            }
        }
    }
    
    func extractPath(after marker: String, from line: String) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        var s = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'"))
        return String(s)
    }
    
    func resolveLogPath(_ text: String, relativeTo root: URL) -> URL {
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        var t = text
        if t.hasPrefix("./") { t.removeFirst(2) }
        return root.appendingPathComponent(t)
    }
    // ===================== /НОРМАЛИЗАЦИЯ =====================
}
