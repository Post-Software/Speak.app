import Foundation
import AVFoundation

final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var outputURL: URL?

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("stt_recording_\(UUID().uuidString).wav")
        outputURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = false
        recorder?.prepareToRecord()
        recorder?.record()

        return fileURL
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
    }
}
