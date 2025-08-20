//
//  FFmpegLocator.swift
//  Analizator
//
//  Created by Виктор Обухов on 07.08.2025.
//

import Foundation

// MARK: - Сервис для работы с FFmpeg
class FFmpegLocator {
    // Возможные пути к ffmpeg/ffprobe (Homebrew Intel/ARM, MacPorts и т.д.)
    static let ffmpegPossiblePaths = [
        "/usr/local/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/local/opt/ffmpeg/bin/ffmpeg"
    ]
    
    static let ffprobePossiblePaths = [
        "/usr/local/bin/ffprobe",
        "/opt/homebrew/bin/ffprobe",
        "/usr/bin/ffprobe",
        "/opt/local/bin/ffprobe",
        "/usr/local/opt/ffmpeg/bin/ffprobe"
    ]
    
    // MARK: - Проверка установки FFmpeg
    static func isFFmpegInstalled() -> Bool {
        return resolvedFFmpegPath() != nil
    }
    
    // MARK: - Получение пути к FFmpeg
    static func resolvedFFmpegPath() -> String? {
        let fm = FileManager.default
        
        // Проверяем известные пути
        for path in ffmpegPossiblePaths {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // Пробуем найти через which
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["ffmpeg"]
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        
        do {
            try proc.run()
            proc.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            return fm.isExecutableFile(atPath: path) ? path : nil
        } catch {
            return nil
        }
    }
    
    // MARK: - Получение пути к FFprobe
    static func resolvedFFprobePath() -> String? {
        return ffprobePossiblePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
