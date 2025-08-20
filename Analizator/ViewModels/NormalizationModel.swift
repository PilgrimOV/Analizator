//
//  Untitled.swift
//  Analizator
//
//  Created by Виктор Обухов on 20.08.2025.
//

import Foundation
import SwiftUI

@MainActor
final class NormalizationModel: ObservableObject {
    // Таблица результатов нормализации
    @Published var results: [NormalizationResult] = []
    // При желании можно вести и текстовый лог отдельно (для отладки)
    @Published var log: String = ""

    // Состояние процесса
    @Published var isNormalizing = false
    @Published private(set) var process: Process?
    @Published var lastRoot: URL?

    // Прогресс по текущему файлу / счетчики (если нужно в UI)
    @Published var currentFile: URL?
    @Published var createdCount = 0

    // Запуск скрипта
    func run(selectedRootFolder: URL?) {
        results.removeAll()
        log = ""
        createdCount = 0
        currentFile = nil
        isNormalizing = true

        guard let scriptPath = Bundle.main.path(forResource: "Normal", ofType: "sh") else {
            log = "❌ Скрипт Normal.sh не найден в бандле."
            isNormalizing = false
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        guard let workDir = (selectedRootFolder ?? lastRoot) else {
            log = "❌ Не выбрана папка для нормализации."
            isNormalizing = false
            return
        }
        lastRoot = workDir

        let p = Process()
        p.currentDirectoryPath = workDir.path
        p.launchPath = "/bin/bash"
        p.arguments = [scriptPath, workDir.path]
        process = p

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe

        var remainder = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let data = h.availableData
            guard !data.isEmpty else { return }

            var chunk = String(decoding: data, as: UTF8.self)
            chunk = chunk.replacingOccurrences(of: #"\u001B\[[0-9;]*m"#, with: "", options: .regularExpression)
                           .replacingOccurrences(of: "\r", with: "")

            chunk = remainder + chunk
            var lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let last = lines.last, !chunk.hasSuffix("\n") { remainder = last; lines.removeLast() } else { remainder = "" }

            Task { @MainActor in
                for line in lines {
                    // 1) Таблица: ловим машинные строки от скрипта
                    if let r = self.parseResultLine(line) {
                        self.results.append(r)
                        continue
                    }
                    // 2) (необязательно) Лог: оставляем только человеческие маркеры
                    if self.shouldKeepInLog(line) {
                        self.log.append(line + "\n")
                        if line.localizedCaseInsensitiveContains("обработка файла:") {
                            self.currentFile = self.resolvePath(fromLogLine: line, base: workDir)
                        }
                        if line.localizedCaseInsensitiveContains("создан новый файл") {
                            self.createdCount += 1
                        }
                    }
                }
            }
        }

        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self.isNormalizing = false
                self.process = nil
            }
        }

        do { try p.run() }
        catch {
            log = "❌ Не удалось запустить скрипт: \(error.localizedDescription)"
            isNormalizing = false
            process = nil
        }
    }

    func stop() {
        process?.interrupt()
        process?.terminate()
        isNormalizing = false
    }

    // MARK: - Парсинг строк вида: ###RESULT key="value" ...
    private func parseResultLine(_ line: String) -> NormalizationResult? {
        guard line.hasPrefix("###RESULT") else { return nil }
        func get(_ k: String) -> String {
            if let r = line.range(of: "\(k)=\"") {
                let s = line[r.upperBound...]
                if let e = s.firstIndex(of: "\"") { return String(s[..<e]) }
            }
            return "?"
        }
        return .init(file: get("file"), method: get("method"), lufs: get("lufs"), tp: get("tp"), status: get("status"))
    }

    // MARK: - Фильтр «читаемого» лога (опционально)
    private func shouldKeepInLog(_ line: String) -> Bool {
        let keepPrefixes = ["✅","⚠️","❌","🔍","🟡","🗂️","📦"]
        if keepPrefixes.contains(where: { line.hasPrefix($0) }) { return true }
        if line.range(of: #"обработка файла\s*:"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if line.contains("Обработка всех файлов завершена успешно")
            || line.contains("Обработка завершена с ошибками") { return true }
        return false
    }

    private func resolvePath(fromLogLine line: String, base: URL) -> URL? {
        guard let r = line.range(of: "Обработка файла:") else { return nil }
        var t = line[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'"))
        if t.hasPrefix("/") { return URL(fileURLWithPath: String(t)) }
        if t.hasPrefix("./") { t.removeFirst(2) }
        return base.appendingPathComponent(String(t))
    }
}
