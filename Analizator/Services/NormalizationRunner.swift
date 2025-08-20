//
//  NormalizationRunner.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation

// MARK: - Сервис для нормализации
class NormalizationRunner {
    @Published var results: [NormalizationResult] = []
    
    // MARK: - Запуск нормализации
    static func run(selectedRootFolder: URL?, 
                   lastNormalizationRoot: URL?,
                   selectedFiles: [URL],
                   onLogUpdate: @escaping (String) -> Void,
                   onProgressUpdate: @escaping (URL?, Set<URL>, Int, Int) -> Void,
                   onCompletion: @escaping () -> Void) -> Process? {
        
        guard let scriptPath = Bundle.main.path(forResource: "Normal", ofType: "sh") else {
            onLogUpdate("❌ Скрипт Normal.sh не найден в бандле.")
            onCompletion()
            return nil
        }
        
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        
        guard let workDir = (selectedRootFolder ?? lastNormalizationRoot ?? selectedFiles.first?.deletingLastPathComponent()) else {
            onLogUpdate("❌ Не выбрана папка для нормализации.")
            onCompletion()
            return nil
        }
        
        let p = Process()
        p.currentDirectoryPath = workDir.path
        p.launchPath = "/bin/bash"
        p.arguments = [scriptPath, workDir.path]
        
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

            let filtered = filterNormalizationChunk(fullText)
            if filtered.isEmpty { return }

            // строгое упорядочивание: одна последовательная очередь + sync на Main
            DispatchQueue.main.async {
                let numbered = addSectionNumbers(to: filtered)
                onLogUpdate(numbered + "\n")
                trackNormalizationProgress(from: numbered, workDir: workDir, onProgressUpdate: onProgressUpdate)
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
                    let filtered = filterNormalizationChunk(tailText)
                    if !filtered.isEmpty {
                        let numberedTail = addSectionNumbers(to: filtered)
                        onLogUpdate(numberedTail + "\n")
                    }
                }

                // 5) финальный ИТОГ — строго в самом конце, с отступом
                onLogUpdate("\nИТОГ: обработка завершена\n")
                onCompletion()
            }
        }

        do { 
            try p.run()
            return p
        } catch {
            onLogUpdate("❌ Не удалось запустить скрипт: \(error.localizedDescription)")
            onCompletion()
            return nil
        }
    }
    
    // MARK: - Остановка нормализации
    static func stop(_ process: Process?) {
        process?.interrupt()   // SIGINT
        process?.terminate()   // SIGTERM
    }
    
    // MARK: - Фильтрация лога
    static func filterNormalizationChunk(_ chunk: String) -> String {
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
    
    // MARK: - Добавление номеров секций
    static func addSectionNumbers(to text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var sectionIndex = 0

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
                sectionIndex += 1
                if sectionIndex > 1, out.last?.isEmpty != true {
                    out.append("") // пустая строка между блоками файлов
                }
                out.append("\(sectionIndex) — \(line)")
            } else {
                out.append(line)
            }
        }

        return out.joined(separator: "\n")
    }
    
    // MARK: - Отслеживание прогресса
    static func trackNormalizationProgress(from chunk: String, 
                                        workDir: URL, 
                                        onProgressUpdate: @escaping (URL?, Set<URL>, Int, Int) -> Void) {
        let lines = chunk.split(separator: "\n").map(String.init)
        var currentFile: URL?
        var normalizedFiles: Set<URL> = []
        var createdCount = 0
        
        for line in lines {
            if let path = extractPath(after: "Обработка файла:", from: line) {
                let url = resolveLogPath(path, relativeTo: workDir)
                currentFile = url
            } else if line.localizedCaseInsensitiveContains("создан новый файл")
                     || line.localizedCaseInsensitiveContains("пропускаем:")
                     || line.contains("✅") {
                if let cur = currentFile { 
                    normalizedFiles.insert(cur) 
                }
                if line.localizedCaseInsensitiveContains("создан новый файл") {
                    createdCount += 1
                }
            }
        }
        
        onProgressUpdate(currentFile, normalizedFiles, 0, createdCount)
    }
    
    // MARK: - Вспомогательные методы
    private static func extractPath(after marker: String, from line: String) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        var s = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'"))
        return String(s)
    }
    
    private static func resolveLogPath(_ text: String, relativeTo root: URL) -> URL {
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        var t = text
        if t.hasPrefix("./") { t.removeFirst(2) }
        return root.appendingPathComponent(t)
    }
}

private func parseResultLine(_ line: String) -> NormalizationResult? {
    guard line.hasPrefix("###RESULT") else { return nil }

    func extract(_ key: String) -> String {
        if let range = line.range(of: "\(key)=\"") {
            let start = line[range.upperBound...]
            if let end = start.firstIndex(of: "\"") {
                return String(start[..<end])
            }
        }
        return "?"
    }

    let file = extract("file")
    let method = extract("method")
    let lufs = extract("lufs")
    let tp = extract("tp")
    let status = extract("status")

    return NormalizationResult(file: file, method: method, lufs: lufs, tp: tp, status: status)
}
