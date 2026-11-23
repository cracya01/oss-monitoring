import SwiftUI
import AppKit
import Darwin

// MARK: - Settings

/// User-editable settings (stored in this app's preferences). Paths may start with "~".
enum Config {
    static let d = UserDefaults.standard
    static let defaults: [String: String] = [
        "mountPath": "~/oss",
        "logPath": "~/Library/Logs/rclone/oss-mount.log",
        "bucket": "",
        "processMatch": "rclone nfsmount",
    ]

    static func value(_ key: String) -> String {
        let v = d.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? (defaults[key] ?? "") : v
    }

    static func set(_ key: String, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || v == defaults[key] { d.removeObject(forKey: key) } else { d.set(v, forKey: key) }
    }

    static var mountDisplay: String { value("mountPath") }
    static var bucket: String { d.string(forKey: "bucket")?.trimmingCharacters(in: .whitespaces) ?? "" }
    static var processMatch: String { value("processMatch") }
}

enum Paths {
    static var mount: String { expand(Config.value("mountPath")) }
    static var log: String { expand(Config.value("logPath")) }

    static func expand(_ p: String) -> String {
        (p as NSString).expandingTildeInPath
    }
}

// MARK: - Model

enum FileState { case queued, done, failed, canceled }

struct FileEntry: Identifiable {
    let path: String
    var id: String { path }
    var state: FileState
    var queuedAt: Date
    var startAt: Date            // queuedAt + rclone's write-back delay
    var finishedAt: Date?
    var message: String?
    var size: Int64?
    var bytesAtStart: Int64?     // rclone cumulative bytes_out when upload was seen starting
}

struct CacheSummary {
    var inUse = 0, toUpload = 0, uploading = 0
    var totalSize = ""
    var at: Date
}

struct LogError: Identifiable {
    let id = UUID()
    let at: Date
    let text: String
}

// MARK: - Helpers

private let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy/MM/dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
}()

private let fullTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

private let dateTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f
}()

private let timeOnly: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

private func match(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }
}

func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
}

func fmtSpeed(_ bps: Double) -> String {
    fmtBytes(Int64(bps)) + "/s"
}

func fmtDuration(_ s: TimeInterval) -> String {
    let t = max(0, Int(s))
    if t < 60 { return "\(t)秒" }
    if t < 3600 { return "\(t / 60)分\(t % 60)秒" }
    return "\(t / 3600)时\((t % 3600) / 60)分"
}

private func runCommand(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

// MARK: - Monitor

@MainActor
final class Monitor: ObservableObject {
    @Published var files: [String: FileEntry] = [:]
    @Published var summary: CacheSummary?
    @Published var errors: [LogError] = []
    @Published var speed: Double = 0
    @Published var mounted = false
    @Published var rclonePID: Int32?
    @Published var now = Date()
    @Published var showErrors = false
    @Published var showSettings = false

    private var offset: UInt64 = 0
    private var partial = ""
    private var live = false
    private var cumulativeOut: Int64?
    private var lastSampleAt: Date?
    private var timer: Timer?
    private var sampling = false

    init() {
        loadInitial()
        live = true
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Starts over with the current settings (after they were changed).
    func reload() {
        files = [:]
        summary = nil
        errors = []
        speed = 0
        offset = 0
        partial = ""
        cumulativeOut = nil
        lastSampleAt = nil
        rclonePID = nil
        live = false
        loadInitial()
        live = true
        tick()
    }

    // Derived lists
    var uploading: [FileEntry] {
        files.values.filter { $0.state == .queued && $0.startAt <= now }.sorted { $0.startAt < $1.startAt }
    }
    var queued: [FileEntry] {
        files.values.filter { $0.state == .queued && $0.startAt > now }.sorted { $0.startAt < $1.startAt }
    }
    var recentDone: [FileEntry] {
        files.values.filter { $0.state != .queued }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .prefix(10).map { $0 }
    }
    var healthy: Bool { mounted && rclonePID != nil }

    /// Estimated (sent, fraction) for an upload; only meaningful when it is the only active upload.
    func estimate(_ f: FileEntry) -> (Int64, Double)? {
        guard uploading.count == 1, let size = f.size, size > 0,
              let start = f.bytesAtStart, let cur = cumulativeOut else { return nil }
        let sent = max(0, cur - start)
        return (min(sent, size), min(Double(sent) / Double(size), 0.99))
    }

    // MARK: Log reading

    private func loadInitial() {
        guard let fh = FileHandle(forReadingAtPath: Paths.log) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > 2_000_000 ? size - 2_000_000 : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        offset = size
        consume(text)
        partial = ""
    }

    private func readNew() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.log),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < offset { offset = 0; partial = "" }      // log rotated / truncated
        guard size > offset, let fh = FileHandle(forReadingAtPath: Paths.log) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        consume(String(decoding: data, as: UTF8.self))
    }

    private func consume(_ chunk: String) {
        let text = partial + chunk
        var lines = text.components(separatedBy: "\n")
        partial = lines.removeLast()
        for l in lines where !l.isEmpty { parse(l) }
    }

    private func parse(_ line: String) {
        guard line.count > 20, let t = tsFormatter.date(from: String(line.prefix(19))) else { return }
        let rest = String(line.dropFirst(20))
        guard let sep = rest.range(of: " : ") else { return }
        let level = rest[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
        let msg = String(rest[sep.upperBound...])

        if let m = match(#"in use (\d+), to upload (\d+), uploading (\d+), total size (\S+)"#, msg) {
            let s = CacheSummary(inUse: Int(m[1]) ?? 0, toUpload: Int(m[2]) ?? 0,
                                 uploading: Int(m[3]) ?? 0, totalSize: m[4], at: t)
            summary = s
            if s.toUpload == 0 && s.uploading == 0 {
                // Nothing pending per rclone: drop queued entries older than this summary.
                for (k, f) in files where f.state == .queued && f.startAt < t { files.removeValue(forKey: k) }
            }
            return
        }

        guard let objSep = msg.range(of: ": ") else {
            if level == "ERROR" { addError(t, msg) }
            return
        }
        let obj = String(msg[..<objSep.lowerBound])
        let body = String(msg[objSep.upperBound...])

        if body.hasPrefix("vfs cache: queuing for upload") {
            var delay: TimeInterval = 5
            if let m = match(#"in (\d+)s$"#, body) { delay = TimeInterval(m[1]) ?? 5 }
            var f = files[obj] ?? FileEntry(path: obj, state: .queued, queuedAt: t, startAt: t)
            if f.state != .queued { f.queuedAt = t; f.bytesAtStart = nil; f.message = nil; f.finishedAt = nil }
            f.state = .queued
            f.startAt = t.addingTimeInterval(delay)
            files[obj] = f
        } else if body.hasPrefix("vfs cache: upload succeeded") {
            finish(obj, .done, t, nil)
        } else if body.hasPrefix("vfs cache: upload canceled") {
            finish(obj, .canceled, t, nil)
        } else if body.hasPrefix("vfs cache: removed cache file as file deleted") {
            if files[obj]?.state == .queued { files.removeValue(forKey: obj) }
        } else if body.hasPrefix("Failed to copy") || body.contains("upload failed") {
            finish(obj, .failed, t, body)
            addError(t, "\(obj): \(body)")
        } else if level == "ERROR" {
            addError(t, msg)
        }
    }

    private func finish(_ path: String, _ state: FileState, _ t: Date, _ message: String?) {
        var f = files[path] ?? FileEntry(path: path, state: state, queuedAt: t, startAt: t)
        f.state = state
        f.finishedAt = t
        f.message = message
        files[path] = f
        let finished = files.values.filter { $0.state != .queued }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        for old in finished.dropFirst(30) { files.removeValue(forKey: old.path) }
    }

    private func addError(_ t: Date, _ text: String) {
        errors.append(LogError(at: t, text: text))
        if errors.count > 10 { errors.removeFirst(errors.count - 10) }
    }

    // MARK: Periodic

    func tick() {
        now = Date()
        readNew()
        mounted = isMounted(Paths.mount)

        for (k, f) in files where f.state == .queued && f.startAt <= now {
            var e = f
            if e.size == nil, let a = try? FileManager.default.attributesOfItem(atPath: Paths.mount + "/" + k) {
                e.size = (a[.size] as? NSNumber)?.int64Value
            }
            if e.bytesAtStart == nil, live, let c = cumulativeOut { e.bytesAtStart = c }
            files[k] = e
        }

        guard !sampling else { return }
        sampling = true
        let knownPID = rclonePID
        let pattern = Config.processMatch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var pid = knownPID
            if pid == nil || kill(pid!, 0) != 0 {
                pid = runCommand("/usr/bin/pgrep", ["-f", pattern])?
                    .split(separator: "\n").first.flatMap { Int32($0) }
            }
            var bytes: Int64?
            if let p = pid, let out = runCommand("/usr/bin/nettop", ["-P", "-L", "1", "-p", String(p), "-J", "bytes_out", "-x"]) {
                let last = out.split(separator: "\n").last.map(String.init) ?? ""
                let cols = last.split(separator: ",", omittingEmptySubsequences: false)
                if cols.count >= 2 { bytes = Int64(cols[1]) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sampling = false
                self.rclonePID = pid
                let t = Date()
                if let b = bytes {
                    if let prev = self.cumulativeOut, let at = self.lastSampleAt, b >= prev {
                        let dt = t.timeIntervalSince(at)
                        if dt > 0 { self.speed = Double(b - prev) / dt }
                    }
                    self.cumulativeOut = b
                    self.lastSampleAt = t
                } else {
                    self.speed = 0
                    self.cumulativeOut = nil
                }
            }
        }
    }

    private func isMounted(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        let mnt = withUnsafePointer(to: &s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mnt == path
    }
}

// MARK: - Views

struct MenuLabel: View {
    @ObservedObject var m: Monitor
    var body: some View {
        let active = !m.uploading.isEmpty
        if !m.healthy {
            Image(systemName: "exclamationmark.icloud")
        } else if active {
            HStack(spacing: 3) {
                Image(systemName: "icloud.and.arrow.up")
                Text(fmtSpeed(m.speed))
            }
        } else if !m.queued.isEmpty {
            Image(systemName: "icloud.and.arrow.up")
        } else {
            Image(systemName: "checkmark.icloud")
        }
    }
}

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

struct ContentView: View {
    @ObservedObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                uploadingSection
                if !m.queued.isEmpty { queuedSection }
                doneSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("查看日志") { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log)) }
                Button {
                    m.showErrors.toggle()
                } label: {
                    Text("错误（\(m.errors.count)）")
                        .foregroundStyle(m.errors.isEmpty ? Color.secondary : Color.red)
                }
                .popover(isPresented: $m.showErrors, arrowEdge: .bottom) { errorPopover }
                Spacer()
                Button("设置") { m.showSettings.toggle() }
                    .popover(isPresented: $m.showSettings, arrowEdge: .bottom) { SettingsView(m: m) }
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("OSS 上传").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(m.healthy ? Color.green : Color.red).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("↑ " + fmtSpeed(m.speed)).font(.system(.callout, design: .monospaced))
                if let s = m.summary {
                    Text("缓存 \(s.totalSize) · 待传 \(s.toUpload) · 上传中 \(s.uploading)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        if m.rclonePID == nil { return "rclone 未运行" }
        if !m.mounted { return "\(Config.mountDisplay) 未挂载" }
        let bucket = Config.bucket
        return bucket.isEmpty ? "已挂载 \(Config.mountDisplay)" : "已挂载 \(Config.mountDisplay) · bucket \(bucket)"
    }

    private var uploadingSection: some View {
        Section(title: "正在上传") {
            if m.uploading.isEmpty {
                Text("没有正在上传的文件").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(m.uploading) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.path).font(.callout).lineLimit(1).truncationMode(.middle)
                    if let (sent, frac) = m.estimate(f) {
                        ProgressView(value: frac)
                        HStack {
                            Text("约 \(fmtBytes(sent)) / \(fmtBytes(f.size ?? 0))")
                            Spacer()
                            if m.speed > 0, let size = f.size {
                                Text("剩余约 " + fmtDuration(Double(size - sent) / m.speed))
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("大小 \(f.size.map(fmtBytes) ?? "未知") · 已用时 \(fmtDuration(m.now.timeIntervalSince(f.startAt)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var queuedSection: some View {
        Section(title: "排队中（\(m.queued.count)）") {
            if m.queued.count > 10 {
                Text("还有 \(m.queued.count - 10) 个未显示").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(m.queued.prefix(10))) { f in
                HStack {
                    Text(f.path).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int(max(0, f.startAt.timeIntervalSince(m.now))))秒后开始")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var doneSection: some View {
        Section(title: "最近完成") {
            if m.recentDone.isEmpty {
                Text("暂无记录").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(m.recentDone) { f in
                HStack(spacing: 6) {
                    Image(systemName: icon(f.state)).foregroundStyle(color(f.state))
                    Text(f.path).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let t = f.finishedAt {
                        Text(dateTime.string(from: t)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .help(f.message ?? "")
            }
        }
    }

    private var errorPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近错误").font(.headline)
            if m.errors.isEmpty {
                Text("没有错误").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(m.errors.reversed()) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fullTime.string(from: e.at))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(e.text)
                                    .font(.caption).foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 320)
            }
        }
        .padding(12)
        .frame(width: 440)
    }

    private func icon(_ s: FileState) -> String {
        switch s {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "minus.circle.fill"
        case .queued: return "clock"
        }
    }

    private func color(_ s: FileState) -> Color {
        switch s {
        case .done: return .green
        case .failed: return .red
        case .canceled, .queued: return .secondary
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject var m: Monitor
    @State private var bucket = Config.d.string(forKey: "bucket") ?? ""
    @State private var mountPath = Config.value("mountPath")
    @State private var logPath = Config.value("logPath")
    @State private var processMatch = Config.value("processMatch")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设置").font(.headline)
            field("Bucket 名称（只用于显示，可留空）", $bucket, "例如 my-bucket")
            field("挂载目录", $mountPath, Config.defaults["mountPath"]!)
            field("rclone 日志文件", $logPath, Config.defaults["logPath"]!)
            field("rclone 进程匹配（pgrep -f）", $processMatch, Config.defaults["processMatch"]!)
            Text("路径可以用 ~ 表示主目录。留空则使用默认值。")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("恢复默认") {
                    bucket = ""
                    mountPath = Config.defaults["mountPath"]!
                    logPath = Config.defaults["logPath"]!
                    processMatch = Config.defaults["processMatch"]!
                }
                Spacer()
                Button("取消") { m.showSettings = false }
                Button("保存") {
                    Config.set("bucket", bucket)
                    Config.set("mountPath", mountPath)
                    Config.set("logPath", logPath)
                    Config.set("processMatch", processMatch)
                    m.showSettings = false
                    m.reload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func field(_ label: String, _ value: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - App

@main
struct OSSMonitorApp: App {
    @StateObject private var monitor = Monitor()
    var body: some Scene {
        MenuBarExtra {
            ContentView(m: monitor)
        } label: {
            MenuLabel(m: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
