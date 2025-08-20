//
//  RegexUtils.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation

// MARK: - Утилиты для работы с регулярными выражениями
extension String {
    // Первая захваченная группа
    func firstMatch(for regex: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: regex, options: []) else { return nil }
        let range = NSRange(location: 0, length: utf16.count)
        guard let m = re.firstMatch(in: self, options: [], range: range) else { return nil }
        if m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: self) {
            return String(self[r])
        }
        return nil
    }
    
    // Форматирование sample rate
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
