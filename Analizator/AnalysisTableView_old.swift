import SwiftUI

struct AnalysisTableView: View {
    // Данные для отображения (передаются извне)
    let results: [AudioAnalysisResult]
    let sortDescriptor: SortDescriptor
    let onSortChange: (SortDescriptor) -> Void

    enum Column: String, CaseIterable {
        case status = "Статус"
        case file = "Файл"
        case lufs = "LUFS"
        case tp = "TP"
        case lra = "LRA"
        case sr = "SR"
    }

    struct SortDescriptor {
        var column: Column
        var ascending: Bool
    }

    var sortedResults: [AudioAnalysisResult] {
        results.sorted {
            switch sortDescriptor.column {
            case .file:
                return sortDescriptor.ascending
                    ? $0.fileURL.lastPathComponent.localizedCompare($1.fileURL.lastPathComponent) == .orderedAscending
                    : $0.fileURL.lastPathComponent.localizedCompare($1.fileURL.lastPathComponent) == .orderedDescending
            case .lufs:
                let l0 = Double($0.lufs ?? "") ?? 0
                let l1 = Double($1.lufs ?? "") ?? 0
                return sortDescriptor.ascending ? l0 < l1 : l0 > l1
            case .tp:
                let t0 = Double($0.truePeak ?? "") ?? 0
                let t1 = Double($1.truePeak ?? "") ?? 0
                return sortDescriptor.ascending ? t0 < t1 : t0 > t1
            case .lra:
                let l0 = Double($0.lra ?? "") ?? 0
                let l1 = Double($1.lra ?? "") ?? 0
                return sortDescriptor.ascending ? l0 < l1 : l0 > l1
            case .sr:
                let s0 = Int($0.sampleRate ?? "") ?? 0
                let s1 = Int($1.sampleRate ?? "") ?? 0
                return sortDescriptor.ascending ? s0 < s1 : s0 > s1
            case .status:
                return sortDescriptor.ascending
                    ? $0.statusPriority < $1.statusPriority
                    : $0.statusPriority > $1.statusPriority
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Заголовки с кнопками сортировки
            HStack {
                ForEach(Column.allCases, id: \.self) { col in
                    Button(action: {
                        if sortDescriptor.column == col {
                            // Меняем порядок сортировки
                            onSortChange(.init(column: col, ascending: !sortDescriptor.ascending))
                        } else {
                            onSortChange(.init(column: col, ascending: true))
                        }
                    }) {
                        HStack(spacing: 2) {
                            Text(col.rawValue)
                                .font(.system(size: 13, weight: .bold))
                            if sortDescriptor.column == col {
                                Image(systemName: sortDescriptor.ascending ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                    }
                    .frame(
                        width: col == .file ? 170 :
                               col == .status ? 36 :
                               col == .lufs ? 80 :
                               col == .tp ? 70 :
                               col == .lra ? 70 : 60,
                        alignment: col == .file ? .leading : .center
                    )
                }
            }
            .padding(.vertical, 5)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedResults) { result in
                        HStack {
                            // 1. Статус — иконка
                            Image(systemName: result.status == .normal ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .foregroundColor(result.status == .normal ? .green : .red)
                                .frame(width: 36)
                            // 2. Имя файла
                            Text(result.fileURL.lastPathComponent)
                                .frame(width: 170, alignment: .leading)
                            // 3. LUFS
                            Text(result.lufs ?? "-")
                                .frame(width: 80, alignment: .center)
                            // 4. TP
                            Text(result.truePeak ?? "-")
                                .frame(width: 70, alignment: .center)
                            // 5. LRA
                            Text(result.lra ?? "-")
                                .frame(width: 70, alignment: .center)
                            // 6. SR
                            Text(result.sampleRate ?? "-")
                                .frame(width: 60, alignment: .center)
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 1.5)
                        Divider()
                    }
                }
            }
        }
    }
}

// Удобство для сортировки по статусу
extension AudioAnalysisResult {
    var statusPriority: Int {
        switch status {
        case .normal: return 0
        case .warning: return 1
        }
    }
}
