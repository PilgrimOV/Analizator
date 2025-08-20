//
//  AudioAnalysisResult.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation

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

// MARK: - Расширения
extension AudioAnalysisResult {
    var statusPriority: Int {
        switch status {
        case .normal: return 0
        case .warning: return 1
        case .unknown: return 2
        }
    }
}
