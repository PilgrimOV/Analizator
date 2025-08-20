//
//  Settings.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation

// MARK: - Константы приложения
struct Settings {
    // Пороговые значения для анализа
    static let okLUFSRange: ClosedRange<Double> = -15.5 ... -13.5
    static let okTruePeakMax: Double = 0.0
    
    // Целевые значения для анализа
    static let analysisTargetI: Double = -14.0
    static let analysisTargetTP: Double = -1.0
    static let analysisTargetLRA: Double = 11.0
}
