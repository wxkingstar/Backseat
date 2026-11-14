import AVFoundation
import Foundation
import Speech

/// macOS 离线语音识别（SpeechAnalyzer），手表录音上传后在这里转成文字。
enum Transcriber {
    static let locale = Locale(identifier: "zh-CN")

    /// 启动时预先下载识别模型，避免第一次说话等很久
    static func prepare() async {
        do {
            guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
            let t = SpeechTranscriber(locale: l, preset: .transcription)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                print("正在下载中文语音识别模型…")
                try await req.downloadAndInstall()
            }
        } catch {
            print("⚠️  语音模型准备失败：\(error.localizedDescription)")
        }
    }

    static func transcribe(_ audio: Data, ext: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backseat-\(UUID().uuidString).\(ext)")
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw NSError(domain: "backseat", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持中文识别"])
        }
        let t = SpeechTranscriber(locale: l, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [t])
        let file = try AVAudioFile(forReading: url)
        async let text: String = t.results.reduce(into: "") { $0 += String($1.text.characters) }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return tidy(try await text)
    }

    /// 去掉识别结果里中文之间、中文标点前多余的空格，保留英文单词间的空格
    static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let cjk = "\\p{Han}"
        let punct = "[，。！？、；：,.!?]"
        t = t.replacingOccurrences(of: "\\s+(?=\(punct))", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=\(cjk))\\s+(?=\(cjk))", with: "", options: .regularExpression)
        return t
    }
}
