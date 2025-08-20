//
//  FileOps.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation
import AppKit

// MARK: - Сервис для операций с файлами
class FileOps {
    // MARK: - Показать в Finder
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    // MARK: - Отображение пути
    static func displayPath(for url: URL) -> String {
        var path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }
        
        if path.count > 60 {
            let comps = path.split(separator: "/")
            if comps.count > 3 {
                path = (path.hasPrefix("~") ? "~/" : "/") + comps.suffix(3).joined(separator: "/")
            }
        }
        
        return path
    }
    
    // MARK: - Общий родитель для URL
    static func commonParent(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        
        var common = first.deletingLastPathComponent()
        
        for url in urls.dropFirst() {
            while !url.deletingLastPathComponent().path.hasPrefix(common.path) {
                guard common.pathComponents.count > 1 else { return nil }
                common.deleteLastPathComponent()
            }
        }
        
        return common.path == "/" ? nil : common
    }
    
    // MARK: - Сбор файлов
    static func collectFiles(from url: URL, into result: inout [URL], allowedExtensions: [String]) {
        var isDir: ObjCBool = false
        
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        result.append(fileURL)
                    }
                }
            }
        } else {
            if allowedExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
    }
    
    // MARK: - Переименование файлов
    static func renameAllInSelectedFolder(root: URL, allowedExtensions: [String]) -> [(old: URL, new: URL)] {
        let fm = FileManager.default
        
        // Берём только файлы из корня выбранной папки (без подпапок)
        let items = (try? fm.contentsOfDirectory(at: root,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        
        // Оставляем только поддерживаемые форматы
        let audioFiles = items
            .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        
        var index = 1
        var renamed: [(old: URL, new: URL)] = []
        
        for oldURL in audioFiles {
            let ext = oldURL.pathExtension
            var base = "Аудио_\(index)"
            var newURL = root.appendingPathComponent(base).appendingPathExtension(ext)
            
            // Если имя занято, просто переходим к следующему номеру
            while fm.fileExists(atPath: newURL.path) {
                index += 1
                base = "Аудио_\(index)"
                newURL = root.appendingPathComponent(base).appendingPathExtension(ext)
            }
            
            do {
                try fm.moveItem(at: oldURL, to: newURL)
                renamed.append((old: oldURL, new: newURL))
                index += 1
            } catch {
                Swift.print("[RENAME] Ошибка '\(oldURL.lastPathComponent)' -> '\(newURL.lastPathComponent)':", error.localizedDescription)
                // продолжаем остальные
            }
        }
        
        return renamed
    }
    
    // MARK: - Удаление старых файлов
    static func deleteOldFilesInSelectedFolder(root: URL, allowedExtensions: [String]) -> [URL] {
        let fm = FileManager.default
        
        // Содержимое ТОЛЬКО текущей папки (без захода в подпапки)
        let items = (try? fm.contentsOfDirectory(at: root,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        
        // Берём только поддерживаемые аудиоформаты
        let audio = items.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
        
        // Оставляем те, у кого НЕТ суффикса _New / _New1 / _New2 ...
        let toTrash = audio.filter { url in
            let base = url.deletingPathExtension().lastPathComponent
            let isNew = base.hasSuffix("_New")
                || (base.range(of: #"_New\d+$"#, options: .regularExpression) != nil)
            return !isNew
        }
        
        var trashed: [URL] = []
        for url in toTrash {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)  // переместить в Корзину
                trashed.append(url)
            } catch {
                Swift.print("[TRASH] Ошибка для \(url.lastPathComponent):", error.localizedDescription)
            }
        }
        
        return trashed
    }
}
