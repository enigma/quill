import AVFoundation

/// The recorders' PCM buffers use float samples. Inspect all channels,
/// including interleaved buffers, without allocating another audio buffer.
func audioPeak(_ buffer: AVAudioPCMBuffer) -> Float {
    guard buffer.format.commonFormat == .pcmFormatFloat32 else { return 0 }
    var peak: Float = 0
    for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        guard let data = audioBuffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        for index in 0..<(Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size) {
            peak = max(peak, abs(samples[index]))
        }
    }
    return peak
}
