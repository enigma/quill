@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Records the Mac's playback mix through ScreenCaptureKit. The stream is
/// configured for audio and has no screen-output delegate, so no video frames
/// are delivered to or stored by quill.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case noDisplay
        case streamStartFailed(Error)
        case audioFormatUnreadable
        case audioBufferUnreadable(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .noDisplay:
                return "no display is available for system-audio capture"
            case .streamStartFailed(let error):
                return "system-audio capture failed: \(error) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .audioFormatUnreadable:
                return "couldn't read the system-audio stream format"
            case .audioBufferUnreadable(let status):
                return "couldn't read a system-audio buffer (OSStatus \(status))"
            case .fileCreationFailed(let error):
                return "system-audio file creation failed: \(error)"
            }
        }
    }

    let activity = CaptureActivity()
    private let queue = DispatchQueue(label: "com.digimata.quill.system-audio")
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private(set) var isRecording = false

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?
    private var capturedFrames: AVAudioFramePosition = 0
    private var capturedPeak: Float = 0

    /// Start an audio-only ScreenCaptureKit stream. macOS may prompt for
    /// Screen Recording permission on first use; after granting it, macOS can
    /// require quill to be relaunched before capture succeeds.
    func start(writingTo url: URL) async throws {
        guard !isRecording else { return }

        activity.begin()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw RecorderError.streamStartFailed(error)
        }
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        // The display is required as a content-filter anchor even though quill
        // registers only an audio output below.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.streamName = "quill system audio"

        let newStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        } catch {
            throw RecorderError.streamStartFailed(error)
        }

        outputURL = url
        firstBufferAt = nil
        capturedFrames = 0
        capturedPeak = 0
        stream = newStream
        isRecording = true

        do {
            try await newStream.startCapture()
        } catch {
            isRecording = false
            stream = nil
            outputURL = nil
            throw RecorderError.streamStartFailed(error)
        }

        FileHandle.standardError.write(Data(
            "system: ScreenCaptureKit audio · 2 ch, 48000 Hz\n".utf8
        ))
    }

    /// Stop capture and finalize the CAF. Waiting for ScreenCaptureKit's stop
    /// completion prevents its callback queue from racing file finalization.
    func stop() {
        guard isRecording else { return }
        isRecording = false

        if let stream {
            let stopped = DispatchSemaphore(value: 0)
            stream.stopCapture { error in
                if let error {
                    FileHandle.standardError.write(Data(
                        "warning: system-audio stream stop failed: \(error)\n".utf8
                    ))
                }
                stopped.signal()
            }
            if stopped.wait(timeout: .now() + 5) == .timedOut {
                FileHandle.standardError.write(Data(
                    "warning: timed out stopping system-audio stream\n".utf8
                ))
            }
        }

        if capturedFrames > 0, capturedPeak == 0 {
            FileHandle.standardError.write(Data(
                "warning: system track contains only digital silence — no Mac output audio was captured\n".utf8
            ))
        }
        cleanup()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, isRecording, sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer)
        else { return }

        activity.receive()
        do {
            try write(sampleBuffer)
        } catch {
            activity.fail("System audio write failed: \(error)")
            FileHandle.standardError.write(Data(
                "system track write failed: \(error)\n".utf8
            ))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        activity.fail("System audio stopped: \(error)")
    }

    private func write(_ sampleBuffer: CMSampleBuffer) throws {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else {
            throw RecorderError.audioFormatUnreadable
        }

        if file == nil {
            guard let outputURL else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
            ]
            do {
                file = try AVAudioFile(
                    forWriting: outputURL,
                    settings: settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
            firstBufferAt = Date()
            FileHandle.standardError.write(Data(
                "system: first audio buffer format=\(format)\n".utf8
            ))
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw RecorderError.audioFormatUnreadable
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw RecorderError.audioBufferUnreadable(status)
        }
        guard let file else { return }
        try file.write(from: buffer)
        let peak = audioPeak(buffer)
        capturedFrames += AVAudioFramePosition(buffer.frameLength)
        capturedPeak = max(capturedPeak, peak)
        activity.saved(frames: buffer.frameLength, peak: peak)
    }

    private func cleanup() {
        stream = nil
        file = nil
        outputURL = nil
        capturedFrames = 0
        capturedPeak = 0
    }
}
