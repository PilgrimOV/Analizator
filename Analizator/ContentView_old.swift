import SwiftUI
import AppKit

// --- Эти структуры лучше оставить в отдельном файле, но для теста можно оставить здесь ---
struct AudioAnalysisResult: Identifiable {
    let id = UUID()
    let fileURL: URL
    let lufs: String?
    let lra: String?
    let truePeak: String?
    let sampleRate: String?
    let status: AnalysisStatus
}

enum AnalysisStatus {
    case normal
    case warning
}

// --- Пути для поиска ffmpeg ---
let ffmpegPossiblePaths = [
    "/usr/local/bin/ffmpeg",
    "/opt/homebrew/bin/ffmpeg",
    "/usr/bin/ffmpeg",
    "/opt/local/bin/ffmpeg",
    "/usr/local/opt/ffmpeg/bin/ffmpeg"
]

struct ContentView: View {
    @State private var selectedFolder: URL? = nil
    @State private var audioFiles: [URL] = []
    @State private var ffmpegOK: Bool? = nil
    @State private var isAnalyzing = false
    @State private var analysisResults: [AudioAnalysisResult] = []
    @State private var sortDescriptor = AnalysisTableView.SortDescriptor(column: .file, ascending: true)

    private let allowedExtensions = ["mp3", "m4a", "mp4"]

    var body: some View {
        HStack(spacing: 0) {
            // --- Левая панель (sidebar) ---
            VStack(alignment: .leading, spacing: 16) {
                Text("Analizator")
                    .font(.title2)
                    .bold()
                    .padding(.top, 8)
                Divider().padding(.bottom, 4)

                Button("Выбрать папку для анализа") {
                    selectFolder()
                }

                if let folder = selectedFolder {
                    Text("Папка: \(folder.path)")
                        .font(.footnote)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("Папка не выбрана")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                }

                Text("Найдено файлов: \(audioFiles.count)")
                    .font(.subheadline)

                if !audioFiles.isEmpty && (ffmpegOK ?? false) {
                    Button(isAnalyzing ? "Анализирую..." : "Анализировать все файлы") {
                        analyzeAllFiles()
                    }
                    .disabled(isAnalyzing)
                }

                // Важно! Показываем предупреждение только если ffmpeg не найден
                if let ffmpegOK = ffmpegOK, ffmpegOK == false {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("FFmpeg не найден!")
                                .bold()
                                .foregroundColor(.red)
                        }
                        Text("Установите через Homebrew:")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Text("brew install ffmpeg")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.red.opacity(0.07))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .frame(width: 230)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider() // Вертикальная линия между панелями

            // --- Правая панель (таблица) ---
            VStack {
                if !analysisResults.isEmpty {
                    AnalysisTableView(
                        results: analysisResults,
                        sortDescriptor: sortDescriptor,
                        onSortChange: { sortDescriptor = $0 }
                    )
                } else {
                    VStack {
                        if audioFiles.isEmpty {
                            Spacer()
                            Text("Нет файлов для анализа")
                                .foregroundColor(.secondary)
                            Spacer()
                        } else {
                            Spacer()
                            Text("Нажмите «Анализировать все файлы», чтобы увидеть результаты")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 520)
        .onAppear {
            ffmpegOK = isFFmpegInstalled()
        }
    }

    // --- Выбор папки ---
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
            audioFiles = findAudioFiles(in: url)
        }
    }

    // --- Рекурсивный поиск файлов ---
    private func findAudioFiles(in folder: URL) -> [URL] {
        var foundFiles: [URL] = []
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let element = enumerator?.nextObject() as? URL {
            if allowedExtensions.contains(element.pathExtension.lowercased()) {
                foundFiles.append(element)
            }
        }
        return foundFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // --- Проверка наличия ffmpeg ---
    private func isFFmpegInstalled() -> Bool {
        let fileManager = FileManager.default
        for path in ffmpegPossiblePaths {
            if fileManager.isExecutableFile(atPath: path) {
                return true
            }
        }
        let process = Process()
        process.launchPath = "/usr/bin/which"
        process.arguments = ["ffmpeg"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !output.isEmpty && fileManager.isExecutableFile(atPath: output)
    }

    // --- Запуск анализа ---
    private func analyzeAllFiles() {
        isAnalyzing = true
        analysisResults = []
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [AudioAnalysisResult] = []
            for file in audioFiles {
                if let result = analyzeFile(url: file) {
                    results.append(result)
                }
            }
            DispatchQueue.main.async {
                self.analysisResults = results
                self.isAnalyzing = false
            }
        }
    }

    // --- Анализ одного файла через ffmpeg ---
    private func analyzeFile(url: URL) -> AudioAnalysisResult? {
        let ffmpegPath = ffmpegPossiblePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg = ffmpegPath else { return nil }
        let process = Process()
        process.launchPath = ffmpeg
        process.arguments = [
            "-hide_banner",
            "-i", url.path,
            "-af", "loudnorm=print_format=summary",
            "-f", "null", "-"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lufs = output.firstMatch(for: "Input Integrated:\\s*(-?\\d+\\.?\\d*)")
        let lra = output.firstMatch(for: "Input LRA:\\s*(-?\\d+\\.?\\d*)")
        let truePeak = output.firstMatch(for: "Input True Peak:\\s*([\\+\\-]?\\d+\\.?\\d*)")
        // Sample rate
        let srProcess = Process()
        srProcess.launchPath = ffmpeg
        srProcess.arguments = ["-hide_banner", "-i", url.path]
        let srPipe = Pipe()
        srProcess.standardOutput = srPipe
        srProcess.standardError = srPipe
        try? srProcess.run()
        srProcess.waitUntilExit()
        let srData = srPipe.fileHandleForReading.readDataToEndOfFile()
        let srOutput = String(data: srData, encoding: .utf8) ?? ""
        let sampleRate = srOutput.firstMatch(for: "(\\d{4,6}) Hz")
        // Оцениваем статус
        let tpVal = Double(truePeak ?? "") ?? 0
        let lufsVal = Double(lufs ?? "") ?? 0
        let srVal = Int(sampleRate ?? "") ?? 0
        let status: AnalysisStatus =
            (tpVal <= -0.5) &&
            (lufsVal >= -14.5 && lufsVal <= -13.5) &&
            (srVal == 44100 || srVal == 48000)
            ? .normal
            : .warning
        return AudioAnalysisResult(
            fileURL: url,
            lufs: lufs,
            lra: lra,
            truePeak: truePeak,
            sampleRate: sampleRate,
            status: status
        )
    }
}

// --- Регулярное выражение для поиска данных ---
extension String {
    func firstMatch(for regex: String) -> String? {
        if let range = self.range(of: regex, options: .regularExpression) {
            let match = String(self[range])
            if let value = match.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) {
                if value.isEmpty, let number = match.components(separatedBy: " ").last {
                    return number.trimmingCharacters(in: .whitespaces)
                }
                return value
            }
        }
        return nil
    }
}
