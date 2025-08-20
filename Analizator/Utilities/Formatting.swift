//
//  Formatting.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation

// MARK: - Утилиты для форматирования
struct Formatting {
    // Форматирование sample rate
    static func formatSampleRate(_ rawValue: String) -> String {
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
}
