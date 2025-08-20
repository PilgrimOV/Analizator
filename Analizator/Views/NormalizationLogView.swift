//
//  NormalizationLogView.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
// 

import SwiftUI

// MARK: - Лог нормализации (как был)
struct NormalizationLogView: View {
    let log: String
    let isProcessing: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                // Крупный моноширинный шрифт + обе прокрутки, без переносов
                Text(log.isEmpty ? "Нет данных." : log)
                    .font(.system(size: 14, weight: .regular, design: .monospaced)) // было .callout → стало 18pt
                    .fixedSize(horizontal: true, vertical: false) // не переносим строки; скроллим по горизонтали
                    .textSelection(.enabled)
                    .padding(10)
            }
            
            if isProcessing {
                Divider()
                HStack {
                    ProgressView()
                    Text("Выполняется нормализация…")
                }
                .padding(10)
            }
        }
    }
}
