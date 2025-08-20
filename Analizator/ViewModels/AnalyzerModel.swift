//
//  AnalyzerModel.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation
import SwiftUI

// MARK: - ViewModel (только АНАЛИЗ)
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
        progressDone = 0
        Swift.print("[UPDATE] Очистили список.")
    }
    
    // MARK: - АНАЛИЗ (публикуем снимки массива)
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
                
                // Публикуем СНИМОК целиком
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
}
