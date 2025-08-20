//
//  Untitled.swift
//  Analizator
//
//  Created by Виктор Обухов on 20.08.2025.
//

import SwiftUI

struct NormalizationTableView: View {
    let results: [NormalizationResult]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("№").font(.footnote).frame(width: 40, alignment: .trailing)
                Text("Статус").font(.footnote).frame(width: 70)
                Text("Файл").font(.footnote).frame(width: 240, alignment: .leading)
                Text("Метод").font(.footnote).frame(width: 120, alignment: .leading)
                Text("LUFS").font(.footnote).frame(width: 70)
                Text("TP").font(.footnote).frame(width: 70)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.1.id) { index, r in
                        HStack(spacing: 0) {
                            Text("\(index + 1)")
                                .frame(width: 40, alignment: .trailing)
                            Text(r.status).frame(width: 70)
                            Text(r.file)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 240, alignment: .leading)
                            Text(r.method).frame(width: 120, alignment: .leading)
                            Text(r.lufs).frame(width: 70)
                            Text(r.tp).frame(width: 70)
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        Divider()
                    }
                }
            }
        }
    }
}
