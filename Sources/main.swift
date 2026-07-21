// rec — minimal meeting recorder for macOS.
//
// Menu bar app: click to record system audio + mic (mixed into one M4A),
// click to stop; the recording is transcribed (AssemblyAI with diarization,
// or whisper.cpp locally) and saved as plain files — one folder per meeting
// under ~/recordings. Files are the API: agents read/grep them directly.
//
// Sibling of `talk` (github.com/brunoqgalvao/talk): same philosophy, one
// Swift file, a Makefile, no dependencies.

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

// MARK: - Config

let home = FileManager.default.homeDirectoryForCurrentUser
let recordingsRoot = home.appendingPathComponent("recordings")
let appSupport = home.appendingPathComponent("Library/Application Support/rec")
let defaultModelURL = appSupport.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin")
let modelDownloadURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

let runningFromAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
let permissionSubject = runningFromAppBundle ? "rec" : "your terminal"

enum Engine: String { case assemblyai, local }

struct Config {
    var engine: Engine?
    var apiKey: String?
    var language = "pt"
    var micGain: Float = 10
    var whisperModel: String?
}

/// ~/.rec holds KEY=VALUE lines: ASSEMBLYAI_API_KEY, ENGINE, LANGUAGE,
/// MIC_GAIN, WHISPER_MODEL. Environment variables win over the file.
func loadConfig() -> Config {
    var c = Config()
    let path = home.appendingPathComponent(".rec").path
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            applyConfig(&c, key: key, value: value)
        }
    }
    for key in ["ASSEMBLYAI_API_KEY", "ENGINE", "LANGUAGE", "MIC_GAIN", "WHISPER_MODEL"] {
        if let value = ProcessInfo.processInfo.environment[key] {
            applyConfig(&c, key: key, value: value)
        }
    }
    return c
}

func applyConfig(_ c: inout Config, key: String, value: String) {
    switch key {
    case "ASSEMBLYAI_API_KEY": c.apiKey = value
    case "ENGINE": c.engine = Engine(rawValue: value)
    case "LANGUAGE": c.language = value
    case "MIC_GAIN": if let g = Float(value), g > 0 { c.micGain = g }
    case "WHISPER_MODEL": c.whisperModel = value
    default: break
    }
}

var config = loadConfig()

/// assemblyai when a key is configured, local otherwise; ENGINE= overrides.
func effectiveEngine() -> Engine {
    if let e = config.engine { return e }
    return config.apiKey != nil ? .assemblyai : .local
}

// MARK: - Store (one folder per meeting; plain files are the API)

struct MeetingStore {
    static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()

    /// ~/recordings/2026-07-20-1830/ (suffix -2, -3… on collision).
    static func newFolder(at date: Date = Date()) throws -> URL {
        let base = folderFormatter.string(from: date)
        var url = recordingsRoot.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsRoot.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func audioURL(_ folder: URL) -> URL { folder.appendingPathComponent("audio.m4a") }
    static func transcriptURL(_ folder: URL) -> URL { folder.appendingPathComponent("transcript.json") }
    static func markdownURL(_ folder: URL) -> URL { folder.appendingPathComponent("meeting.md") }
    static func pendingURL(_ folder: URL) -> URL { folder.appendingPathComponent("transcript.pending") }

    /// Meeting folders that recorded fine but still lack a transcript.
    static func pendingFolders() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { FileManager.default.fileExists(atPath: pendingURL($0).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Transcript rendering

struct Utterance {
    let speaker: String
    let text: String
}

/// meeting.md: readable, greppable, speaker-labelled when we have speakers.
func renderMarkdown(date: Date, duration: TimeInterval, engine: String,
                    utterances: [Utterance], plainText: String?) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    let mins = Int(duration) / 60, secs = Int(duration) % 60
    var md = "# Meeting \(f.string(from: date))\n\n"
    md += "- duration: \(mins)m\(String(format: "%02d", secs))s\n"
    md += "- engine: \(engine)\n\n"
    if !utterances.isEmpty {
        for u in utterances {
            md += "**[\(u.speaker)]** \(u.text)\n\n"
        }
    } else if let text = plainText, !text.isEmpty {
        md += text + "\n"
    } else {
        md += "_(no speech detected)_\n"
    }
    return md
}

// MARK: - AssemblyAI engine

enum TranscribeError: Error, CustomStringConvertible {
    case api(String)
    case local(String)
    var description: String {
        switch self {
        case .api(let m): return "assemblyai: \(m)"
        case .local(let m): return "whisper local: \(m)"
        }
    }
}

struct TranscriptResult {
    let rawJSON: Data
    let utterances: [Utterance]
    let plainText: String
    let engine: String
}

func assemblyaiTranscribe(audio: URL, apiKey: String) throws -> TranscriptResult {
    func request(_ url: String, method: String, body: Data?, contentType: String?) throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        req.timeoutInterval = 120
        var result: Result<Data, Error>?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error {
                result = .failure(error)
            } else if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                result = .failure(TranscribeError.api("HTTP \(http.statusCode) \(body.prefix(200))"))
            } else {
                result = .success(data ?? Data())
            }
            sem.signal()
        }.resume()
        sem.wait()
        switch result! {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }

    let audioData = try Data(contentsOf: audio)
    let uploadResp = try request("https://api.assemblyai.com/v2/upload", method: "POST",
                                 body: audioData, contentType: "application/octet-stream")
    guard let upload = try JSONSerialization.jsonObject(with: uploadResp) as? [String: Any],
          let uploadURL = upload["upload_url"] as? String else {
        throw TranscribeError.api("bad upload response")
    }

    let jobBody = try JSONSerialization.data(withJSONObject: [
        "audio_url": uploadURL,
        "speaker_labels": true,
        "language_code": config.language,
        "speech_model": "best",
    ])
    let jobResp = try request("https://api.assemblyai.com/v2/transcript", method: "POST",
                              body: jobBody, contentType: "application/json")
    guard let job = try JSONSerialization.jsonObject(with: jobResp) as? [String: Any],
          let id = job["id"] as? String else {
        throw TranscribeError.api("bad transcript response")
    }

    let deadline = Date().addingTimeInterval(15 * 60)
    while true {
        Thread.sleep(forTimeInterval: 3)
        let poll = try request("https://api.assemblyai.com/v2/transcript/\(id)",
                               method: "GET", body: nil, contentType: nil)
        guard let data = try JSONSerialization.jsonObject(with: poll) as? [String: Any],
              let status = data["status"] as? String else {
            throw TranscribeError.api("bad poll response")
        }
        if status == "error" {
            throw TranscribeError.api(data["error"] as? String ?? "unknown error")
        }
        if status == "completed" {
            let utts = (data["utterances"] as? [[String: Any]] ?? []).compactMap { u -> Utterance? in
                guard let text = u["text"] as? String, !text.isEmpty else { return nil }
                return Utterance(speaker: u["speaker"] as? String ?? "?", text: text)
            }
            return TranscriptResult(rawJSON: poll, utterances: utts,
                                    plainText: data["text"] as? String ?? "",
                                    engine: "assemblyai")
        }
        if Date() > deadline { throw TranscribeError.api("timed out after 15min") }
    }
}

// MARK: - Local whisper engine (whisper.cpp, optional)

func findWhisperCLI() -> String? {
    for path in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"] {
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

func whisperModelPath() -> String? {
    if let m = config.whisperModel, FileManager.default.fileExists(atPath: m) { return m }
    if FileManager.default.fileExists(atPath: defaultModelURL.path) { return defaultModelURL.path }
    return nil
}

func run(_ launchPath: String, _ args: [String]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    p.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, text)
}

func localTranscribe(audio: URL) throws -> TranscriptResult {
    guard let cli = findWhisperCLI() else {
        throw TranscribeError.local("whisper-cli not found — brew install whisper-cpp")
    }
    guard let model = whisperModelPath() else {
        throw TranscribeError.local("no model — run `rec setup-local` to download it")
    }
    let wav = audio.deletingPathExtension().appendingPathExtension("16k.wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let (convStatus, convOut) = try run("/usr/bin/afconvert",
                                        ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                                         audio.path, wav.path])
    guard convStatus == 0 else { throw TranscribeError.local("afconvert: \(convOut.prefix(200))") }

    let outBase = audio.deletingLastPathComponent().appendingPathComponent(".whisper-out").path
    defer { try? FileManager.default.removeItem(atPath: outBase + ".txt") }
    // -mc 0 avoids whisper's repetition loops on meeting audio.
    let (status, output) = try run(cli, ["-m", model, "-l", config.language, "-mc", "0",
                                         "--no-prints", "-otxt", "-of", outBase,
                                         "-f", wav.path])
    guard status == 0 else { throw TranscribeError.local("whisper-cli: \(output.prefix(200))") }
    let text = (try? String(contentsOfFile: outBase + ".txt", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let raw = try JSONSerialization.data(withJSONObject: ["engine": "whisper-local", "text": text])
    return TranscriptResult(rawJSON: raw, utterances: [], plainText: text, engine: "whisper-local")
}

// MARK: - Transcription pipeline

/// Transcribe a finished recording folder: assemblyai first (when configured),
/// local as fallback; on total failure leave transcript.pending with the
/// reason so `rec retry` can pick it up.
func transcribeFolder(_ folder: URL, date: Date, duration: TimeInterval) -> Result<TranscriptResult, Error> {
    let audio = MeetingStore.audioURL(folder)
    var errors: [String] = []

    if effectiveEngine() == .assemblyai, let key = config.apiKey {
        do {
            let result = try assemblyaiTranscribe(audio: audio, apiKey: key)
            try save(result, folder: folder, date: date, duration: duration)
            return .success(result)
        } catch {
            errors.append("\(error)")
        }
    }
    do {
        let result = try localTranscribe(audio: audio)
        try save(result, folder: folder, date: date, duration: duration)
        if !errors.isEmpty {
            // Remote failed but local saved the day — still note what happened.
            fputs("rec: assemblyai failed (\(errors.joined())), used local whisper\n", stderr)
        }
        return .success(result)
    } catch {
        errors.append("\(error)")
    }
    let reason = errors.joined(separator: "; ")
    try? reason.write(to: MeetingStore.pendingURL(folder), atomically: true, encoding: .utf8)
    return .failure(TranscribeError.api(reason))
}

func save(_ result: TranscriptResult, folder: URL, date: Date, duration: TimeInterval) throws {
    try result.rawJSON.write(to: MeetingStore.transcriptURL(folder))
    let md = renderMarkdown(date: date, duration: duration, engine: result.engine,
                            utterances: result.utterances, plainText: result.plainText)
    try md.write(to: MeetingStore.markdownURL(folder), atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(at: MeetingStore.pendingURL(folder))
}

// MARK: - Recorder (system audio via ScreenCaptureKit + mic, mixed)

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var backgroundActivity: NSObjectProtocol?

    // Mic samples resampled to 48k mono, waiting to be mixed into the next
    // system-audio buffer. Touched from the mic tap and the SCK queue.
    private let micLock = NSLock()
    private var pendingMicSamples: [Float] = []

    private(set) var isRecording = false
    private(set) var folder: URL?
    private(set) var startedAt: Date?
    private var systemBuffers = 0
    private var micBuffers = 0

    func start() async throws {
        guard !isRecording else { return }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw NSError(domain: "rec", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Screen Recording permission missing for \(permissionSubject) — System Settings → Privacy & Security → Screen Recording"])
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw NSError(domain: "rec", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Microphone blocked for \(permissionSubject) — System Settings → Privacy & Security → Microphone"])
        default: break
        }

        let folder = try MeetingStore.newFolder()
        self.folder = folder
        let audioURL = MeetingStore.audioURL(folder)

        // AAC 16kHz mono 32kbps: speech-tuned, ~4KB/s, encoder downmixes the
        // 48kHz stereo input on the fly.
        let w = try AVAssetWriter(outputURL: audioURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ])
        input.expectsMediaDataInRealTime = true
        guard w.canAdd(input) else {
            throw NSError(domain: "rec", code: 3, userInfo: [NSLocalizedDescriptionKey: "asset writer rejected input"])
        }
        w.add(input)
        writer = w
        writerInput = input
        sessionStarted = false
        pendingMicSamples.removeAll()
        systemBuffers = 0
        micBuffers = 0

        // System audio: the 2×2px @1fps video stream is the documented trick
        // to unlock audio-only capture on macOS 14.
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "rec", code: 4, userInfo: [NSLocalizedDescriptionKey: "no display to capture"])
        }
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 5
        cfg.showsCursor = false
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio,
                              sampleHandlerQueue: DispatchQueue(label: "dev.rec.audio"))
        try await s.startCapture()
        stream = s

        // Mic: a FRESH engine every session — a long-lived engine keeps a
        // stale device binding after the default input changes (AirPods…).
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            try? await s.stopCapture()
            stream = nil
            throw NSError(domain: "rec", code: 5, userInfo: [NSLocalizedDescriptionKey: "no audio input device"])
        }
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.enqueueMic(buffer)
        }
        try engine.start()
        audioEngine = engine

        guard w.startWriting() else {
            throw w.error ?? NSError(domain: "rec", code: 6, userInfo: [NSLocalizedDescriptionKey: "writer failed to start"])
        }

        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording meeting audio")
        startedAt = Date()
        isRecording = true
    }

    /// Returns (folder, duration, hadAudio).
    func stop() async -> (URL, TimeInterval, Bool)? {
        guard isRecording, let folder, let startedAt else { return nil }
        isRecording = false
        let duration = Date().timeIntervalSince(startedAt)

        if let stream { try? await stream.stopCapture() }
        stream = nil
        audioEngine?.stop()
        if let engine = audioEngine { engine.inputNode.removeTap(onBus: 0) }
        audioEngine = nil

        writerInput?.markAsFinished()
        if let writer, writer.status == .writing {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                writer.finishWriting { c.resume() }
            }
        }
        writer = nil
        writerInput = nil
        if let activity = backgroundActivity {
            ProcessInfo.processInfo.endActivity(activity)
            backgroundActivity = nil
        }

        let hadAudio = systemBuffers > 0 || micBuffers > 0
        self.folder = nil
        self.startedAt = nil
        return (folder, duration, hadAudio)
    }

    // Mic tap: mono-ize, resample to 48k by linear interpolation (avoids
    // AVAudioConverter's stateful bugs), queue for mixing. Audio thread.
    private func enqueueMic(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        micBuffers += 1

        let inRate = buffer.format.sampleRate
        let outRate = 48000.0
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = channels[0][i] }

        var out: [Float]
        if abs(inRate - outRate) < 100 {
            out = mono
        } else {
            let ratio = outRate / inRate
            let count = Int(ceil(Double(frames) * ratio))
            out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let src = Double(i) / ratio
                let idx = Int(src)
                let frac = Float(src - Double(idx))
                if idx + 1 < frames {
                    out[i] = mono[idx] * (1 - frac) + mono[idx + 1] * frac
                } else if idx < frames {
                    out[i] = mono[idx]
                }
            }
        }

        micLock.lock()
        pendingMicSamples.append(contentsOf: out)
        if pendingMicSamples.count > 48000 { // cap the backlog at ~1s
            pendingMicSamples.removeFirst(pendingMicSamples.count - 48000)
        }
        micLock.unlock()
    }

    // SCK audio callback (dev.rec.audio queue): mix mic in place, append.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, isRecording,
              let writer, let input = writerInput else { return }

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid else { return }
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }
        systemBuffers += 1

        mixMicInPlace(sampleBuffer)
        if !input.append(sampleBuffer), let error = writer.error {
            fputs("rec: writer error: \(error.localizedDescription)\n", stderr)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("rec: capture stream stopped: \(error.localizedDescription)\n", stderr)
    }

    /// Adds pending mic samples into the system buffer's float samples,
    /// handling both interleaved and planar stereo, with tanh soft limiting.
    private func mixMicInPlace(_ systemBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(systemBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let blockBuffer = CMSampleBufferGetDataBuffer(systemBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let data = dataPointer, length > 0,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else { return }

        let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
        guard channels > 0, bytesPerSample == 4 else { return }
        let frames = length / (channels * bytesPerSample)

        micLock.lock()
        let mic: [Float]
        if pendingMicSamples.count >= frames {
            mic = Array(pendingMicSamples.prefix(frames))
            pendingMicSamples.removeFirst(frames)
        } else {
            mic = pendingMicSamples + [Float](repeating: 0,
                                              count: frames - pendingMicSamples.count)
            pendingMicSamples.removeAll()
        }
        micLock.unlock()

        let gain = config.micGain
        let ptr = UnsafeMutableRawPointer(data).assumingMemoryBound(to: Float.self)
        @inline(__always) func limit(_ x: Float) -> Float { tanh(x) }

        if planar && channels == 2 {
            // [L0…Ln, R0…Rn]
            for i in 0..<frames {
                let m = mic[i] * gain
                ptr[i] = limit(ptr[i] + m)
                ptr[frames + i] = limit(ptr[frames + i] + m)
            }
        } else {
            // interleaved [L0, R0, L1, R1, …] (or mono)
            for i in 0..<frames {
                let m = mic[i] * gain
                for ch in 0..<channels {
                    ptr[i * channels + ch] = limit(ptr[i * channels + ch] + m)
                }
            }
        }
    }
}

// MARK: - Config file writing

/// Updates KEY=VALUE lines in ~/.rec in place, preserving everything else,
/// then reloads the live config.
func updateConfigFile(_ values: [String: String]) {
    let url = home.appendingPathComponent(".rec")
    var lines = (try? String(contentsOf: url, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
    while lines.last?.isEmpty == true { lines.removeLast() }
    var remaining = values
    for (i, line) in lines.enumerated() {
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
        if let value = remaining.removeValue(forKey: String(line[..<eq])) {
            lines[i] = "\(line[..<eq])=\(value)"
        }
    }
    for (key, value) in remaining.sorted(by: { $0.key < $1.key }) {
        lines.append("\(key)=\(value)")
    }
    try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    config = loadConfig()
}

/// Jumps straight to a Privacy & Security pane (e.g. "Privacy_Microphone").
func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Recording island (wraps the notch, DynamicNotchKit-style)
//
// On notch Macs: a black shape glued to the top edge, wider than the notch,
// with top corners curving inward — it merges with the physical notch and the
// content (red dot / timer / stop) lives on its sides. On other displays: a
// floating pill below the menu bar. Ported from ambien's RecordingIsland.

struct NotchInfo {
    static var hasNotch: Bool {
        guard let screen = NSScreen.main, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.width > 0, right.width > 0 else { return false }
        let width = screen.frame.width - left.width - right.width
        return width > 150 && width < 300
    }

    static var notchWidth: CGFloat {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 200 }
        return screen.frame.width - left.width - right.width
    }

    static var notchHeight: CGFloat {
        max(NSScreen.main?.safeAreaInsets.top ?? 38, 38)
    }
}

/// Rounded rect whose top corners curve INWARD, matching the notch's own
/// curvature, so the shape reads as an extension of the notch.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat = 6
    var bottomCornerRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
                       control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
                       control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
                       control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return p
    }
}

final class IslandModel: ObservableObject {
    enum Mode { case recording(Date), transcribing }
    @Published var mode: Mode = .transcribing
    @Published var tick = Date() // heartbeat so the timer text refreshes
}

struct RecIslandView: View {
    @ObservedObject var model: IslandModel
    let hasNotch: Bool
    let onStop: () -> Void
    @State private var hovered = false

    private let leftWidth: CGFloat = 50
    private let rightCompact: CGFloat = 70
    private let rightExpanded: CGFloat = 110

    private var isRecording: Bool {
        if case .recording = model.mode { return true }
        return false
    }

    private var timerText: String {
        guard case .recording(let start) = model.mode else { return "" }
        let s = Int(model.tick.timeIntervalSince(start))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var body: some View {
        Group {
            if hasNotch { notchBody } else { pillBody }
        }
        .onHover { hovered = $0 }
    }

    // MARK: notch variant

    private var expandedWidth: CGFloat { leftWidth + NotchInfo.notchWidth + rightExpanded }
    private var visibleWidth: CGFloat {
        isRecording ? leftWidth + NotchInfo.notchWidth + (hovered ? rightExpanded : rightCompact)
                    : leftWidth + NotchInfo.notchWidth + leftWidth
    }

    private var notchBody: some View {
        ZStack(alignment: .leading) {
            NotchShape().fill(Color.black)
            HStack(spacing: 0) {
                Group {
                    if isRecording {
                        PulsingDot(color: .red, size: 10)
                    } else {
                        PulsingDot(color: .white.opacity(0.85), size: 9)
                    }
                }
                .frame(width: leftWidth)
                Spacer().frame(width: NotchInfo.notchWidth)
                HStack(spacing: 8) {
                    if isRecording {
                        Text(timerText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                        Button(action: onStop) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.red))
                        }
                        .buttonStyle(.plain)
                        .opacity(hovered ? 1 : 0)
                    }
                }
                .frame(width: rightExpanded, alignment: .leading)
            }
        }
        .frame(width: expandedWidth, height: NotchInfo.notchHeight, alignment: .leading)
        .mask(
            HStack(spacing: 0) {
                NotchShape()
                    .frame(width: visibleWidth, height: NotchInfo.notchHeight, alignment: .leading)
                Spacer(minLength: 0)
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { if isRecording { onStop() } }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: visibleWidth)
    }

    // MARK: floating pill fallback (no notch)

    private var pillBody: some View {
        HStack(spacing: 10) {
            if isRecording {
                PulsingDot(color: .red, size: 9)
                Text(timerText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                if hovered {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            } else {
                PulsingDot(color: .white.opacity(0.85), size: 9)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(white: 0.08)))
        .contentShape(Capsule())
        .onTapGesture { if isRecording { onStop() } }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// Owns the island panel; same API the app uses regardless of notch.
final class RecordingIsland {
    private var panel: NSPanel?
    private let model = IslandModel()
    private var clock: Timer?
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    func showRecording(startedAt: Date) {
        model.mode = .recording(startedAt)
        model.tick = Date()
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.tick = Date()
        }
        present()
    }

    func showTranscribing() {
        clock?.invalidate()
        clock = nil
        model.mode = .transcribing
        present()
    }

    func hide() {
        clock?.invalidate()
        clock = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.panel = nil
        })
    }

    private func present() {
        if panel != nil {
            panel?.orderFrontRegardless()
            return
        }
        let hasNotch = NotchInfo.hasNotch
        let view = RecIslandView(model: model, hasNotch: hasNotch) { [weak self] in
            self?.onStop()
        }
        let hosting = NSHostingView(rootView: view)

        let size: NSSize = hasNotch
            ? NSSize(width: 50 + NotchInfo.notchWidth + 110, height: NotchInfo.notchHeight)
            : NSSize(width: 180, height: 36)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = !hasNotch
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        hosting.frame = NSRect(origin: .zero, size: size)
        p.contentView = hosting

        if let screen = NSScreen.main {
            if hasNotch {
                // Align the shape so its notch spacer sits exactly on the notch.
                let x = screen.frame.midX - NotchInfo.notchWidth / 2 - 50
                let y = screen.frame.maxY - size.height
                p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            } else {
                p.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                                         y: screen.frame.maxY - 60))
            }
        }

        panel = p
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
    }
}

// MARK: - Settings window

final class SettingsController: NSObject {
    private var window: NSWindow?
    private let engineControl = NSSegmentedControl(labels: ["AssemblyAI", "On-device"],
                                                   trackingMode: .selectOne, target: nil, action: nil)
    private let engineCaption = NSTextField(wrappingLabelWithString: "")
    private let keyField = NSTextField()
    private let keyEntryRow = NSStackView()
    private let keyAddedLabel = NSTextField(labelWithString: "")
    private let keyAddedRow = NSStackView()
    private let gainSlider = NSSlider(value: 10, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let gainValue = NSTextField(labelWithString: "")
    private var permissionRows: [(dot: NSTextField, granted: () -> Bool)] = []
    private var permissionsTimer: Timer?

    func show() {
        if window == nil { build() }
        refresh()
        refreshPermissions()
        permissionsTimer?.invalidate()
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
            self.refreshPermissions()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 360
        return label
    }

    private func build() {
        engineControl.target = self
        engineControl.action = #selector(engineToggled)
        engineControl.segmentDistribution = .fillEqually

        engineCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        engineCaption.textColor = .secondaryLabelColor
        engineCaption.isSelectable = false
        engineCaption.preferredMaxLayoutWidth = 360

        keyField.placeholderString = "AssemblyAI API key"
        keyField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let add = NSButton(title: "Add", target: self, action: #selector(addKeyTapped))
        add.keyEquivalent = "\r"
        add.bezelStyle = .rounded
        keyEntryRow.orientation = .horizontal
        keyEntryRow.addArrangedSubview(keyField)
        keyEntryRow.addArrangedSubview(add)

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill",
                                               accessibilityDescription: "key added")!)
        let replace = NSButton(title: "Replace…", target: self, action: #selector(replaceKeyTapped))
        replace.bezelStyle = .inline
        replace.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyAddedRow.orientation = .horizontal
        keyAddedRow.spacing = 6
        keyAddedRow.addArrangedSubview(check)
        keyAddedRow.addArrangedSubview(keyAddedLabel)
        keyAddedRow.addArrangedSubview(NSView())
        keyAddedRow.addArrangedSubview(replace)

        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        gainValue.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        gainValue.textColor = .secondaryLabelColor
        let gainRow = NSStackView(views: [NSTextField(labelWithString: "Mic gain"), gainSlider, gainValue])
        gainRow.orientation = .horizontal
        gainRow.spacing = 8
        gainSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let permsTitle = NSTextField(labelWithString: "Permissions")
        permsTitle.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        permsTitle.textColor = .secondaryLabelColor
        let permissionsGroup = NSStackView(views: [permsTitle])
        permissionsGroup.orientation = .vertical
        permissionsGroup.alignment = .leading
        permissionsGroup.spacing = 6
        let permissions: [(String, () -> Bool, String)] = [
            ("Microphone", { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
             "Privacy_Microphone"),
            ("Screen Recording (system audio)", { CGPreflightScreenCaptureAccess() },
             "Privacy_ScreenCapture"),
        ]
        for (name, granted, anchor) in permissions {
            let dot = NSTextField(labelWithString: "●")
            dot.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let open = NSButton(title: "Open…", target: self, action: #selector(openPermissionPane(_:)))
            open.bezelStyle = .inline
            open.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            open.identifier = NSUserInterfaceItemIdentifier(anchor)
            let row = NSStackView(views: [dot, label, NSView(), open])
            row.orientation = .horizontal
            row.spacing = 6
            permissionsGroup.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: permissionsGroup.widthAnchor).isActive = true
            permissionRows.append((dot, granted))
        }

        let stack = NSStackView(views: [engineControl, engineCaption, keyEntryRow, keyAddedRow,
                                        gainRow, permissionsGroup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: engineCaption)
        stack.setCustomSpacing(20, after: gainRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [engineControl, engineCaption, keyEntryRow, keyAddedRow, permissionsGroup] {
            view.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }

        let win = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "rec Settings"
        win.contentView = stack
        win.isReleasedWhenClosed = false
        win.collectionBehavior = .moveToActiveSpace
        stack.layoutSubtreeIfNeeded()
        win.setContentSize(stack.fittingSize)
        win.center()
        window = win
    }

    private func refresh() {
        let assemblyai = effectiveEngine() == .assemblyai
        engineControl.selectedSegment = assemblyai ? 0 : 1
        engineCaption.stringValue = assemblyai
            ? "Best quality: speaker-labelled transcripts via AssemblyAI. Falls back to on-device whisper if a request fails."
            : "Free, private, offline — whisper.cpp on this Mac. No speaker labels; noticeably weaker on meetings."
        let hasKey = (config.apiKey?.count ?? 0) > 8
        if let key = config.apiKey, hasKey {
            keyAddedLabel.stringValue = "Key added · \(key.prefix(3))…\(key.suffix(4))"
        }
        keyEntryRow.isHidden = hasKey
        keyAddedRow.isHidden = !hasKey
        gainSlider.doubleValue = Double(config.micGain)
        gainValue.stringValue = String(format: "%.0f×", config.micGain)
    }

    private func refreshPermissions() {
        for (dot, granted) in permissionRows {
            dot.textColor = granted() ? .systemGreen : .systemRed
        }
    }

    @objc private func openPermissionPane(_ sender: NSButton) {
        if let anchor = sender.identifier?.rawValue { openPrivacyPane(anchor) }
    }

    @objc private func engineToggled() {
        if engineControl.selectedSegment == 1 {
            updateConfigFile(["ENGINE": "local"])
        } else if config.apiKey != nil {
            updateConfigFile(["ENGINE": "assemblyai"])
        } else {
            engineControl.selectedSegment = 1 // no key yet — stay local
            keyField.becomeFirstResponder()
        }
        refresh()
    }

    @objc private func addKeyTapped() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        guard key.count > 8 else { return }
        updateConfigFile(["ASSEMBLYAI_API_KEY": key, "ENGINE": "assemblyai"])
        keyField.stringValue = ""
        refresh()
    }

    @objc private func replaceKeyTapped() {
        keyAddedRow.isHidden = true
        keyEntryRow.isHidden = false
        keyField.becomeFirstResponder()
    }

    @objc private func gainChanged() {
        updateConfigFile(["MIC_GAIN": String(format: "%.0f", gainSlider.doubleValue)])
        gainValue.stringValue = String(format: "%.0f×", config.micGain)
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let recorder = Recorder()
    private let settings = SettingsController()
    private var pill: RecordingIsland!
    private let toggleItem = NSMenuItem()
    private let statusLine = NSMenuItem()
    private var clock: Timer?
    private var transcribing = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        pill = RecordingIsland { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.stopFlow()
        }
        updateIcon()

        let menu = NSMenu()
        toggleItem.title = "Start Recording"
        toggleItem.action = #selector(toggleRecording)
        toggleItem.target = self
        menu.addItem(toggleItem)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Recordings", action: #selector(openRecordings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        if runningFromAppBundle {
            let login = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit rec",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        // Ask for the mic up front; Screen Recording prompts on first start().
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if recorder.isRecording {
            let icon = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "recording")
            icon?.isTemplate = false
            button.image = icon
            button.contentTintColor = .systemRed
        } else if transcribing > 0 {
            let icon = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "transcribing")
            icon?.isTemplate = true
            button.image = icon
            button.contentTintColor = nil
            button.title = ""
        } else {
            let icon = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "rec")
            icon?.isTemplate = true
            button.image = icon
            button.contentTintColor = nil
            button.title = ""
        }
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            stopFlow()
        } else {
            startFlow()
        }
    }

    private func startFlow() {
        Task { @MainActor in
            do {
                try await recorder.start()
                NSSound(named: "Pop")?.play()
                pill.showRecording(startedAt: recorder.startedAt ?? Date())
                toggleItem.title = "Stop Recording"
                clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self, let started = self.recorder.startedAt else { return }
                    let s = Int(Date().timeIntervalSince(started))
                    self.statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
                }
                updateIcon()
            } catch {
                NSSound(named: "Basso")?.play()
                fputs("rec: \(error.localizedDescription)\n", stderr)
                showError(error.localizedDescription)
            }
        }
    }

    private func stopFlow() {
        Task { @MainActor in
            guard let (folder, duration, hadAudio) = await recorder.stop() else { return }
            clock?.invalidate()
            clock = nil
            statusItem.button?.title = ""
            toggleItem.title = "Start Recording"
            NSSound(named: "Bottle")?.play()

            guard hadAudio else {
                NSSound(named: "Basso")?.play()
                pill.hide()
                showError("no audio captured — check Screen Recording + Microphone permissions")
                try? FileManager.default.removeItem(at: folder)
                updateIcon()
                return
            }

            transcribing += 1
            pill.showTranscribing()
            updateIcon()
            let date = Date().addingTimeInterval(-duration)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = transcribeFolder(folder, date: date, duration: duration)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.transcribing -= 1
                    self.updateIcon()
                    if self.transcribing == 0, !self.recorder.isRecording { self.pill.hide() }
                    switch result {
                    case .success:
                        NSSound(named: "Glass")?.play()
                    case .failure(let error):
                        NSSound(named: "Basso")?.play()
                        self.showError("transcription failed (audio kept, `rec retry`): \(error)")
                    }
                }
            }
            updateIcon()
        }
    }

    private func showError(_ message: String) {
        statusLine.title = "⚠ \(message.prefix(80))"
    }

    @objc private func openRecordings() {
        NSWorkspace.shared.open(recordingsRoot)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func toggleLaunchAtLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if recorder.isRecording, let started = recorder.startedAt {
            let s = Int(Date().timeIntervalSince(started))
            statusLine.title = String(format: "Recording… %d:%02d", s / 60, s % 60)
        } else if transcribing > 0 {
            statusLine.title = "Transcribing…"
        } else {
            let pending = MeetingStore.pendingFolders().count
            let engine = effectiveEngine() == .assemblyai ? "AssemblyAI" : "whisper local"
            statusLine.title = pending > 0
                ? "Engine: \(engine) · \(pending) pending (rec retry)"
                : "Engine: \(engine)"
        }
    }
}

// MARK: - CLI commands

func cmdCheck() {
    let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    print("microphone: \(mic ? "OK" : "NOT GRANTED (\(permissionSubject))")")
    print("screen recording: \(CGPreflightScreenCaptureAccess() ? "OK" : "NOT GRANTED (\(permissionSubject))")")
    print("engine: \(effectiveEngine().rawValue)")
    print("assemblyai key: \(config.apiKey != nil ? "OK" : "missing (ASSEMBLYAI_API_KEY in ~/.rec)")")
    let cli = findWhisperCLI()
    print("whisper-cli: \(cli ?? "not installed (brew install whisper-cpp)")")
    print("whisper model: \(whisperModelPath() ?? "missing (rec setup-local)")")
    let pending = MeetingStore.pendingFolders()
    print("recordings: \(recordingsRoot.path)\(pending.isEmpty ? "" : " · \(pending.count) pending")")
}

func cmdRetry() {
    let pending = MeetingStore.pendingFolders()
    guard !pending.isEmpty else {
        print("nothing pending")
        return
    }
    for folder in pending {
        print("transcribing \(folder.lastPathComponent) …")
        let audio = MeetingStore.audioURL(folder)
        let attrs = try? FileManager.default.attributesOfItem(atPath: audio.path)
        let date = attrs?[.creationDate] as? Date ?? Date()
        let asset = AVURLAsset(url: audio)
        let duration = CMTimeGetSeconds(asset.duration)
        switch transcribeFolder(folder, date: date, duration: duration.isFinite ? duration : 0) {
        case .success(let r):
            print("  ok (\(r.engine), \(r.utterances.count) utterances)")
        case .failure(let e):
            print("  FAILED: \(e)")
        }
    }
}

func cmdSetupLocal() {
    try? FileManager.default.createDirectory(at: defaultModelURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: defaultModelURL.path) {
        print("model already at \(defaultModelURL.path)")
        return
    }
    print("downloading ggml-large-v3-turbo-q5_0 (~550MB) …")
    let (status, out) = (try? run("/usr/bin/curl", ["-SL", "-o", defaultModelURL.path,
                                                    modelDownloadURL])) ?? (1, "curl failed")
    print(status == 0 ? "done: \(defaultModelURL.path)" : "FAILED: \(out.prefix(300))")
}

func cmdSelftest() {
    var failures = 0
    func expect(_ cond: Bool, _ name: String) {
        print("\(cond ? "PASS" : "FAIL") \(name)")
        if !cond { failures += 1 }
    }

    var c = Config()
    applyConfig(&c, key: "ENGINE", value: "local")
    applyConfig(&c, key: "MIC_GAIN", value: "4.5")
    applyConfig(&c, key: "MIC_GAIN", value: "-3") // invalid, keep previous
    expect(c.engine == .local, "config: engine parsed")
    expect(c.micGain == 4.5, "config: gain parsed, invalid rejected")

    let md = renderMarkdown(date: Date(timeIntervalSince1970: 0), duration: 754,
                            engine: "assemblyai",
                            utterances: [Utterance(speaker: "A", text: "olá"),
                                         Utterance(speaker: "B", text: "oi")],
                            plainText: nil)
    expect(md.contains("12m34s"), "markdown: duration formatted")
    expect(md.contains("**[A]** olá"), "markdown: speaker turns")

    let empty = renderMarkdown(date: Date(), duration: 5, engine: "x",
                               utterances: [], plainText: nil)
    expect(empty.contains("no speech"), "markdown: empty transcript notes silence")

    let name = MeetingStore.folderFormatter.string(from: Date())
    let shapeOK = name.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}$"#, options: .regularExpression) != nil
    expect(shapeOK, "store: folder name shape")

    print(failures == 0 ? "all selftests passed" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "check": cmdCheck(); exit(0)
case "retry": cmdRetry(); exit(0)
case "setup-local": cmdSetupLocal(); exit(0)
case "register-login":
    // Must run from inside the app bundle so SMAppService targets rec.app:
    //   /Applications/rec.app/Contents/MacOS/rec register-login
    guard runningFromAppBundle else {
        fputs("rec: run this from the app bundle: /Applications/rec.app/Contents/MacOS/rec register-login\n", stderr)
        exit(1)
    }
    do {
        try SMAppService.mainApp.register()
        print("launch at login: enabled")
        exit(0)
    } catch {
        fputs("rec: register failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case "selftest": cmdSelftest()
case "--help", "-h", "help":
    print("""
        rec — minimal meeting recorder (system audio + mic)

        usage: rec [check|retry|setup-local|selftest]

          (no args)    run the menu bar app
          check        diagnose permissions, keys and engines
          retry        transcribe recordings that are still pending
          setup-local  download the local whisper model (~550MB)
          selftest     run unit tests

        config: ~/.rec with KEY=VALUE lines — ASSEMBLYAI_API_KEY, ENGINE
        (assemblyai|local), LANGUAGE (default pt), MIC_GAIN (default 10),
        WHISPER_MODEL (path). Recordings land in ~/recordings, one folder per
        meeting: audio.m4a + transcript.json + meeting.md.
        """)
    exit(0)
case .some(let other):
    fputs("rec: unknown argument \(other) (try --help)\n", stderr)
    exit(1)
case nil:
    break
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
