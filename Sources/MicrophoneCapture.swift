import Foundation
import AVFoundation

/// Bounded speech segments, emitted after a pause or at six seconds of speech.
struct SpeechSegmenter {
    static let sampleRate = 16000
    private var samples: [Float] = [], lead: [Float] = []
    private var quiet = 0, voiced = 0
    mutating func append(_ input: [Float]) -> [Data] {
        guard !input.isEmpty else { return [] }
        let values = input.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
        let speech = rms >= 0.012
        if samples.isEmpty && !speech { lead = Array((lead + values).suffix(Self.sampleRate / 5)); return [] }
        if samples.isEmpty { samples = lead; lead = [] }
        samples += values
        if speech { quiet = 0; voiced += values.count } else { quiet += values.count }
        if quiet >= Self.sampleRate * 3 / 5 || samples.count >= Self.sampleRate * 6 { return finish().map { [$0] } ?? [] }
        return []
    }
    mutating func finish() -> Data? {
        defer { samples = []; lead = []; quiet = 0; voiced = 0 }
        guard voiced >= Self.sampleRate / 3 else { return nil }
        return Self.wav(samples)
    }
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); integer(UInt32(36 + samples.count * 2)); text("WAVEfmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2)); integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(samples.count * 2))
        for value in samples { integer(Int16(max(-1, min(1, value.isFinite ? value : 0)) * 32767)) }
        return data
    }
}

private final class MicrophoneCollector: @unchecked Sendable {
    let converter: AVAudioConverter
    let output: AVAudioFormat
    let onSegment: @Sendable (Data) -> Void
    let onLevel: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var segmenter = SpeechSegmenter()
    private var suspended = false
    init(format: AVAudioFormat, onSegment: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw LaunchError.message("无法读取此麦克风的音频格式") }
        self.converter = converter; output = target; self.onSegment = onSegment; self.onLevel = onLevel
    }
    func suspend(_ value: Bool) { lock.lock(); suspended = value; if value { segmenter = SpeechSegmenter() }; lock.unlock() }
    func finish() -> Data? { lock.lock(); defer { lock.unlock() }; return segmenter.finish() }
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !suspended else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false, error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
        let values = Array(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        onLevel(sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count)))
        for segment in segmenter.append(values) { onSegment(segment) }
    }
}

@MainActor final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var collector: MicrophoneCollector?
    func start(onSegment: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw LaunchError.message("麦克风权限未开启，请在系统设置的隐私与安全性中允许 ModelDock 使用麦克风。") }
        let engine = AVAudioEngine(), input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw LaunchError.message("未找到可用的麦克风，请检查系统声音输入。") }
        let collector = try MicrophoneCollector(format: format, onSegment: onSegment, onLevel: onLevel)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak collector] buffer, _ in collector?.consume(buffer) }
        engine.prepare()
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine; self.collector = collector
    }
    func suspend(_ value: Bool) { collector?.suspend(value) }
    @discardableResult func stop(flush: Bool = false) -> Data? {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        let final = flush ? collector?.finish() : nil
        engine = nil; collector = nil
        return final
    }
}
