import SwiftUI

struct AnalysisTableView: View {
    let results: [AudioAnalysisResult]
    let sortDescriptor: SortDescriptor
    let onSortChange: (SortDescriptor) -> Void
    
    enum Column: String, CaseIterable {
        case status = "Статус"
        case file   = "Файл"
        case lufs   = "LUFS"
        case tp     = "TP"
        case lra    = "LRA"
        case sr     = "SR"
    }
    struct SortDescriptor { var column: Column; var ascending: Bool }
    
    var body: some View {
        VStack(spacing: 0) {
            // Заголовки
            HStack {
                header(.status, width: 60)
                header(.file,   width: 340, align: .leading)
                header(.lufs,   width: 80)
                header(.tp,     width: 70)
                header(.lra,    width: 70)
                header(.sr,     width: 90)
            }
            .padding(.vertical, 6)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            
            // Строки
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Через индексы — обновляется всегда надёжно
                    ForEach(results.indices, id: \.self) { i in
                        let r = results[i]
                        HStack(spacing: 0) {
                            // Статус
                            HStack {
                                switch r.status {
                                case .unknown:
                                    Image(systemName: "questionmark.circle.fill").foregroundColor(.gray)
                                case .normal:
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                case .warning:
                                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                                }
                            }
                            .frame(width: 60)
                            
                            // Имя файла
                            Text(r.fileURL.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 340, alignment: .leading)
                            
                            // Значения
                            Text(r.lufs?.isEmpty == false ? r.lufs! : "–").frame(width: 80)
                            Text(r.truePeak?.isEmpty == false ? r.truePeak! : "–").frame(width: 70)
                            Text(r.lra?.isEmpty == false ? r.lra! : "–").frame(width: 70)
                            Text(r.sampleRate?.isEmpty == false ? r.sampleRate! : "–").frame(width: 90)
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Заголовок с сортировкой
    private func header(_ column: Column, width: CGFloat, align: Alignment = .center) -> some View {
        Button {
            if sortDescriptor.column == column {
                onSortChange(.init(column: column, ascending: !sortDescriptor.ascending))
            } else {
                onSortChange(.init(column: column, ascending: true))
            }
        } label: {
            HStack(spacing: 4) {
                Text(column.rawValue).font(.system(size: 13, weight: .semibold))
                
                if sortDescriptor.column == column {
                    Image(systemName: sortDescriptor.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: align)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: align)
        .contentShape(Rectangle())
        .help("Сортировка по «\(column.rawValue)»")
    }
}
