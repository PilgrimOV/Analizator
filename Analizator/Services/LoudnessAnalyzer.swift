//
//  LoudnessAnalyzer.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation

// MARK: - Сервис для анализа громкости
class LoudnessAnalyzer {
    
    // MARK: - Анализ одного файла
    static func analyzeFile(url: URL) -> AudioAnalysisResult? {
        guard let ffmpeg = FFmpegLocator.resolvedFFmpegPath() else {
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
            "-af", "loudnorm=I=\(Settings.analysisTargetI):TP=\(Settings.analysisTargetTP):LRA=\(Settings.analysisTargetLRA):print_format=json",
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

        // Декодируем «безотказно»: любые не-UTF-8 байты заменяются на
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

        let isOK = Settings.okLUFSRange.contains(lufsVal) && (tpVal <= Settings.okTruePeakMax) && srOK
        let status: AnalysisStatus = (lufs == nil && tp == nil) ? .unknown : (isOK ? .normal : .warning)
        
        return AudioAnalysisResult(fileURL: url, lufs: lufs, lra: lra, truePeak: tp, sampleRate: sampleRate, status: status)
    }
    
    // MARK: - Получение sample rate
    static func getSampleRate(for url: URL) -> String? {
        if let ffprobe = FFmpegLocator.resolvedFFprobePath() {
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
                    return Formatting.formatSampleRate(raw)
                }
            } catch {
                Swift.print("[FFPROBE] ошибка:", error.localizedDescription)
            }
        }
        // fallback через ffmpeg -i
        if let ffmpeg = FFmpegLocator.resolvedFFmpegPath() {
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
}
