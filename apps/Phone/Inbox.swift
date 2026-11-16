import AVFoundation
import Observation
import Speech
import SwiftUI

struct InboxItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var date = Date()
    /// 还没识别成文字时，录音文件名（在 Documents/inbox 下）
    var audio: String?
}

/// 灵感收件箱：连不上 Mac 时，说的话先存在手机上，用手机自带的识别转成文字；连上以后再发给 Claude。
@MainActor @Observable
final class Inbox {
    static let shared = Inbox()

    var items: [InboxItem] = Inbox.load() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "inbox") }
    }

    private static func load() -> [InboxItem] {
        guard let d = UserDefaults.standard.data(forKey: "inbox"),
              let list = try? JSONDecoder().decode([InboxItem].self, from: d) else { return [] }
        return list
    }

    private static var folder: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("inbox")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 存一段录音（16kHz 单声道 Int16），马上开始识别
    func add(pcm: Data) {
        guard pcm.count > 16_000 else { return }   // 不到半秒的不存
        var item = InboxItem(text: "")
        let name = "\(item.id.uuidString).wav"
        do { try Self.wav(pcm).write(to: Self.folder.appendingPathComponent(name)) } catch { return }
        item.audio = name
        items.insert(item, at: 0)
        Task { await transcribe(item.id) }
    }

    /// 把还没识别出来的再试一遍（比如上次没网、识别模型还没下载好）
    func retryPending() {
        for item in items where item.audio != nil && item.text.isEmpty {
            Task { await transcribe(item.id) }
        }
    }

    func remove(_ id: UUID) {
        if let name = items.first(where: { $0.id == id })?.audio {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name))
        }
        items.removeAll { $0.id == id }
    }

    private func transcribe(_ id: UUID) async {
        guard let name = items.first(where: { $0.id == id })?.audio else { return }
        let url = Self.folder.appendingPathComponent(name)
        // 识别出错（比如模型还没下载好）：保留录音，下次打开收件箱再试
        guard let text = try? await PhoneTranscriber.transcribe(url),
              let i = items.firstIndex(where: { $0.id == id }) else { return }
        // 识别成功但没有内容（没说话、太小声）：标出来，不再一直转圈
        items[i].text = text.isEmpty ? "（没识别出内容）" : text
        items[i].audio = nil
        try? FileManager.default.removeItem(at: url)
    }

    private static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + UInt32(pcm.count)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}

/// 手机本机的中文离线识别（和 Mac 端兜底用的是同一套系统能力）
enum PhoneTranscriber {
    static func prepare() async {
        guard #available(iOS 26.0, *) else { return }
        guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else { return }
        let t = SpeechTranscriber(locale: l, preset: .transcription)
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
    }

    static func transcribe(_ url: URL) async throws -> String {
        guard #available(iOS 26.0, *) else { return "" }
        guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else { return "" }
        let t = SpeechTranscriber(locale: l, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [t])
        let file = try AVAudioFile(forReading: url)
        async let text: String = t.results.reduce(into: "") { $0 += String($1.text.characters) }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        // 去掉识别结果里中文之间、标点前多余的空格
        var s = try await text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\\s+(?=[，。！？、；：,.!?])", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<=\\p{Han})\\s+(?=\\p{Han})", with: "", options: .regularExpression)
        return s
    }
}

// MARK: - 界面

/// 主屏上的提示条：收件箱里有东西时才出现
struct InboxBanner: View {
    @Environment(PhoneStore.self) private var store
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill").foregroundStyle(P.accent)
                Text("灵感收件箱 \(Inbox.shared.items.count) 条").font(.subheadline.weight(.semibold)).foregroundStyle(P.text)
                Text(store.connected ? "可以发给 Claude 了" : "连上 Mac 后发送").font(.footnote).foregroundStyle(P.text2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(P.text3)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
        }
        .buttonStyle(PressStyle(fill: P.card, radius: 14))
    }
}

struct InboxSheet: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var inbox = Inbox.shared
        NavigationStack {
            List {
                if !store.connected {
                    Label("连不上 Mac。说的话先存在这里，连上以后再发。", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(P.warnText)
                }
                ForEach($inbox.items) { $item in
                    VStack(alignment: .leading, spacing: 8) {
                        if item.audio != nil && item.text.isEmpty {
                            HStack(spacing: 8) { ProgressView(); Text("正在识别…").foregroundStyle(.secondary) }
                        } else {
                            TextField("内容", text: $item.text, axis: .vertical)
                        }
                        HStack {
                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("发送") {
                                store.send(item.text)
                                inbox.remove(item.id)
                            }
                            .buttonStyle(.borderedProminent).tint(P.ok)
                            .disabled(!store.connected || item.text.isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions { Button("删除", role: .destructive) { inbox.remove(item.id) } }
                }
                if inbox.items.isEmpty {
                    Text("收件箱是空的").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("灵感收件箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                let ready = inbox.items.filter { !$0.text.isEmpty }
                if ready.count > 1 {
                    Button {
                        // 合成一条消息发出去，每条一行
                        store.send(ready.map(\.text).joined(separator: "\n"))
                        ready.forEach { inbox.remove($0.id) }
                    } label: {
                        Text("合并成一条发给 Claude（\(ready.count) 条）").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent).tint(P.ok)
                    .disabled(!store.connected)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .onAppear { inbox.retryPending() }
        }
    }
}
