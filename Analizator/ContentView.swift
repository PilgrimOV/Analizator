import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Модель результата анализа (общая для обоих файлов)
struct AudioAnalysisResult: Identifiable, Equatable {
    var id: String { fileURL.path }   // стабильный идентификатор по пути файла
    let fileURL: URL
    var lufs: String?
    var lra: String?
    var truePeak: String?
    var sampleRate: String?
    var status: AnalysisStatus
    
    static func == (lhs: AudioAnalysisResult, rhs: AudioAnalysisResult) -> Bool {
        lhs.fileURL == rhs.fileURL
    }
}

enum AnalysisStatus { case unknown, normal, warning }

// Возможные пути к ffmpeg/ffprobe (Homebrew Intel/ARM, MacPorts и т.д.)
private let ffmpegPossiblePaths = [
    "/usr/local/bin/ffmpeg",
    "/opt/homebrew/bin/ffmpeg",
    "/usr/bin/ffmpeg",
    "/opt/local/bin/ffmpeg",
    "/usr/local/opt/ffmpeg/bin/ffmpeg"
]
private let ffprobePossiblePaths = [
    "/usr/local/bin/ffprobe",
    "/opt/homebrew/bin/ffprobe",
    "/usr/bin/ffprobe",
    "/opt/local/bin/ffprobe",
    "/usr/local/opt/ffmpeg/bin/ffprobe"
]

// Пороговые значения (твои правила)
private let okLUFSRange: ClosedRange<Double> = -15.5 ... -13.5
private let okTruePeakMax: Double = 0.0

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
    
    private let normLogQueue = DispatchQueue(label: "norm.log.append.queue")

    let allowedExtensions = ["mp3", "m4a", "mp4"]
    
    // MARK: - Вспомогательные
    func isFFmpegInstalled() -> Bool { resolvedFFmpegPath() != nil }
    func resolvedFFmpegPath() -> String? {
        let fm = FileManager.default
        for p in ffmpegPossiblePaths { if fm.isExecutableFile(atPath: p) { return p } }
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["ffmpeg"]
        let pipe = Pipe(); proc.standardOutput = pipe
        try? proc.run(); proc.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: path) ? path : nil
    }
    
    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func displayPath(for url: URL) -> String {
        var path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        if path.count > 60 {
            let comps = path.split(separator: "/")
            if comps.count > 3 {
                path = (path.hasPrefix("~") ? "~/" : "/") + comps.suffix(3).joined(separator: "/")
            }
        }
        return path
    }
    
    func commonParent(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var common = first.deletingLastPathComponent()
        for u in urls.dropFirst() {
            while !u.deletingLastPathComponent().path.hasPrefix(common.path) {
                guard common.pathComponents.count > 1 else { return nil }
                common.deleteLastPathComponent()
            }
        }
        return common.path == "/" ? nil : common
    }
    
    func collectFiles(from url: URL, into result: inout [URL]) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let f as URL in e {
                    if allowedExtensions.contains(f.pathExtension.lowercased()) { result.append(f) }
                }
            }
        } else {
            if allowedExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
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
                guard let res = self.analyzeFile(url: file) else {
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
    
    // Анализ одного файла
    func analyzeFile(url: URL) -> AudioAnalysisResult? {
        guard let ffmpeg = resolvedFFmpegPath() else {
            Swift.print("[FFMPEG] не найден")
            return nil
        }
        let p = Process()
        p.launchPath = ffmpeg
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        p.environment = env
        p.arguments = [
            "-hide_banner", "-nostats",
            "-i", url.path,
            "-map", "0:a:0", "-vn", "-sn", "-dn",
            "-af", "loudnorm=I=-14:TP=-1.0:LRA=11:print_format=json",
            "-f", "null", "-"
        ]
        
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        
        do { try p.run() } catch {
            Swift.print("[FFMPEG] ошибка запуска:", error.localizedDescription)
            return nil
        }
        
        let proc = p
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if proc.isRunning {
                Swift.print("[FFMPEG] timeout → terminate:", url.lastPathComponent)
                proc.terminate()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        // Декодируем «безотказно»: любые не-UTF-8 байты заменяются на �
        // (важно для русских ID3-тегов в «нестандартной» кодировке)
        let output = String(decoding: data, as: UTF8.self)

        Swift.print("[FFMPEG] \(url.lastPathComponent) raw bytes:", data.count)
        if output.isEmpty { Swift.print("[FFMPEG] пустой вывод для", url.lastPathComponent) }
        
        // --- Парсинг loudnorm: сначала вытаскиваем значения по ключам из всего вывода ---
        var lufs: String? = nil
        var tp:   String? = nil
        var lra:  String? = nil

        // 0) Готовим «чистый» текст: убираем ANSI, \r и «необычные» пробелы
        let clean = output
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: #"\u001B\[[0-9;]*m"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")

        // 1) Утилита: первая захваченная группа
        func rx(_ pattern: String, _ text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let m = re.firstMatch(in: text, options: [], range: range),
                  m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }

        // 2) Прямо по ключам (работает даже если JSON окружён лишним текстом)
        lufs = rx(#""input_i"\s*:\s*"?([-+]?\d+(?:[.,]\d+)?)"?"#, clean)
        tp   = rx(#""input_tp"\s*:\s*"?([-+]?\d+(?:[.,]\d+)?)"?"#, clean)
        lra  = rx(#""input_lra"\s*:\s*"?(\d+(?:[.,]\d+)?)"?"#, clean)

        // 3) Если не нашли — fallback: вырезаем объект { … "input_i" … } и парсим JSON
        if lufs == nil || tp == nil || lra == nil,
           let re = try? NSRegularExpression(pattern: #"\{[\s\S]*?"input_i"[\s\S]*?\}"#),
           let m  = re.firstMatch(in: clean, options: [], range: NSRange(clean.startIndex..., in: clean)),
           let r  = Range(m.range, in: clean)
        {
            let jsonText = String(clean[r])
            if let jdata = jsonText.data(using: .utf8),
               let obj   = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any]
            {
                lufs = (obj["input_i"]  as? String) ?? (obj["input_i"]  as? NSNumber)?.stringValue
                tp   = (obj["input_tp"] as? String) ?? (obj["input_tp"] as? NSNumber)?.stringValue
                lra  = (obj["input_lra"]as? String) ?? (obj["input_lra"]as? NSNumber)?.stringValue
            }
        }

        // 4) Десятичная точка
        lufs = lufs?.replacingOccurrences(of: ",", with: ".")
        tp   = tp?.replacingOccurrences(of: ",", with: ".")
        lra  = lra?.replacingOccurrences(of: ",", with: ".")

        // 5) Диагностика на крайний случай
        if lufs == nil || tp == nil || lra == nil {
            Swift.print("[PARSE-FAIL]", url.lastPathComponent, "exit:", p.terminationStatus)
            try? String(clean.prefix(20000)).write(
                to: URL(fileURLWithPath: "/tmp/analizator-\(url.lastPathComponent).log"),
                atomically: true, encoding: .utf8
            )
        }

        // Sample rate через ffprobe (если есть), иначе из ffmpeg -i
        let sampleRate = getSampleRate(for: url)
        
        Swift.print("[PARSE] \(url.lastPathComponent) -> LUFS:\(lufs ?? "nil") TP:\(tp ?? "nil") LRA:\(lra ?? "nil") SR:\(sampleRate ?? "nil")")
        
        // Статус (LUFS + TP + SR 44.1/48 kHz)
        let lufsVal = Double(lufs ?? "") ?? .infinity
        let tpVal   = Double(tp   ?? "") ?? .infinity

        // SR считаем «ОК», если 44.1 kHz или 48 kHz.
        // Если SR не удалось получить (nil) — не наказываем (считаем ОК).
        let srOK: Bool = {
            guard let sr = sampleRate else { return true }
            // вытащим число из "44.1 kHz" / "48 kHz" / "96 kHz" и т.п.
            let numeric = sr.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
            guard let value = Double(numeric) else { return true }
            return abs(value - 44.1) < 0.05 || abs(value - 48.0) < 0.05
        }()

        let isOK = okLUFSRange.contains(lufsVal) && (tpVal <= okTruePeakMax) && srOK
        let status: AnalysisStatus = (lufs == nil && tp == nil) ? .unknown : (isOK ? .normal : .warning)
        
        return AudioAnalysisResult(fileURL: url, lufs: lufs, lra: lra, truePeak: tp, sampleRate: sampleRate, status: status)
    }
    
    // Получение sample rate
    func getSampleRate(for url: URL) -> String? {
        if let ffprobe = ffprobePossiblePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let p = Process()
            p.launchPath = ffprobe
            p.arguments = [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=sample_rate",
                "-of", "default=nw=1:nk=1",
                url.path
            ]
            var env = ProcessInfo.processInfo.environment
            env["LC_ALL"] = "C"
            env["LANG"]   = "C"
            p.environment = env

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do {
                try p.run()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let raw = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    return formatSampleRate(raw)
                }
            } catch {
                Swift.print("[FFPROBE] ошибка:", error.localizedDescription)
            }
        }
        // fallback через ffmpeg -i
        if let ffmpeg = resolvedFFmpegPath() {
            let p2 = Process()
            p2.launchPath = ffmpeg
            p2.arguments = ["-hide_banner", "-v", "error", "-i", url.path]
            let pipe2 = Pipe()
            p2.standardError = pipe2
            p2.standardOutput = Pipe()
            try? p2.run()
            let d2 = pipe2.fileHandleForReading.readDataToEndOfFile()
            p2.waitUntilExit()
            let out2 = String(data: d2, encoding: .utf8) ?? ""
            if let sr = out2.firstMatch(for: #"(\d{4,6})\s*Hz"#) {
                return sr.formattedSampleRate()
            }
        }
        return nil
    }
    
    private func formatSampleRate(_ rawValue: String) -> String {
        guard let hz = Int(rawValue) else { return rawValue }
        switch hz {
        case 44100: return "44.1 kHz"
        case 48000: return "48 kHz"
        case 96000: return "96 kHz"
        case 192000: return "192 kHz"
        default:
            let kHz = Double(hz) / 1000.0
            return String(format: "%.1f kHz", kHz)
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
            self.normLogQueue.async {
                DispatchQueue.main.sync {
                    let numbered = self.addSectionNumbers(to: filtered)
                    self.normalizationLog.append(numbered + "\n")
                    self.trackNormalizationProgress(from: numbered, workDir: workDir)
                }
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

            self.normLogQueue.async {
                DispatchQueue.main.sync {
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
                        Text("LUFS −13.5…−15.5, TP ≤ 0.0, SR 44.1/48 kHz").font(.footnote)
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
                return sortDescriptor.ascending ? numA < numB : numA > numB
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
            let fm = FileManager.default

            // Берём только файлы из корня выбранной папки (без подпапок)
            let items = (try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            // Оставляем только поддерживаемые форматы
            let audioFiles = items
                .filter { model.allowedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

            var index = 1
            var renamed: [(old: URL, new: URL)] = []

            for oldURL in audioFiles {
                let ext = oldURL.pathExtension
                var base = "Аудио_\(index)"
                var newURL = root.appendingPathComponent(base).appendingPathExtension(ext)

                // Если имя занято, просто переходим к следующему номеру
                while fm.fileExists(atPath: newURL.path) {
                    index += 1
                    base = "Аудио_\(index)"
                    newURL = root.appendingPathComponent(base).appendingPathExtension(ext)
                }

                do {
                    try fm.moveItem(at: oldURL, to: newURL)
                    renamed.append((old: oldURL, new: newURL))
                    index += 1
                } catch {
                    Swift.print("[RENAME] Ошибка '\(oldURL.lastPathComponent)' -> '\(newURL.lastPathComponent)':", error.localizedDescription)
                    // продолжаем остальные
                }
            }

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
            let fm = FileManager.default

            // Содержимое ТОЛЬКО текущей папки (без захода в подпапки)
            let items = (try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []

            // Берём только поддерживаемые аудиоформаты
            let audio = items.filter { model.allowedExtensions.contains($0.pathExtension.lowercased()) }

            // Оставляем те, у кого НЕТ суффикса _New / _New1 / _New2 ...
            let toTrash = audio.filter { url in
                let base = url.deletingPathExtension().lastPathComponent
                let isNew = base.hasSuffix("_New")
                    || (base.range(of: #"_New\d+$"#, options: .regularExpression) != nil)
                return !isNew
            }

            var trashed: [URL] = []
            for url in toTrash {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)  // переместить в Корзину
                    trashed.append(url)
                } catch {
                    Swift.print("[TRASH] Ошибка для \(url.lastPathComponent):", error.localizedDescription)
                }
            }

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

// MARK: - Лог нормализации (как был)
struct NormalizationLogView: View {
    let log: String
    let isProcessing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                // Крупный моноширинный шрифт + обе прокрутки, без переносов
                Text(log.isEmpty ? "Нет данных." : log)
                    .font(.system(size: 14, weight: .regular, design: .monospaced)) // было .callout → стало 18pt
                    .fixedSize(horizontal: true, vertical: false) // не переносим строки; скроллим по горизонтали
                    .textSelection(.enabled)
                    .padding(10)
            }
            
            if isProcessing {
                Divider()
                HStack {
                    ProgressView()
                    Text("Выполняется нормализация…")
                }
                .padding(10)
            }
        }
    }
}

// MARK: - Утилиты
extension AudioAnalysisResult {
    var statusPriority: Int {
        switch status {
        case .normal: return 0
        case .warning: return 1
        case .unknown: return 2
        }
    }
}
extension String {
    func firstMatch(for regex: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: regex, options: []) else { return nil }
        let range = NSRange(location: 0, length: utf16.count)
        guard let m = re.firstMatch(in: self, options: [], range: range) else { return nil }
        if m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: self) {
            return String(self[r])
        }
        return nil
    }
    func formattedSampleRate() -> String {
        if let hz = Int(self.components(separatedBy: CharacterSet.whitespaces).first ?? "") {
            if hz == 44100 { return "44.1 kHz" }
            if hz == 48000 { return "48 kHz" }
            let k = Double(hz) / 1000
            return String(format: "%.1f kHz", k)
        }
        return self
    }
}
