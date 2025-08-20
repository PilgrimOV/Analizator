//
//  NormalizationResult.swift
//  Analizator
//
//  Created by Виктор Обухов on 20.08.2025.
//

import Foundation

struct NormalizationResult: Identifiable {
    let id = UUID()
    let file: String
    let method: String
    let lufs: String
    let tp: String
    let status: String
}
