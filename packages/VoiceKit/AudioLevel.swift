import AVFAudio
import Accelerate

/// The loudness of a block of audio for display: its RMS mapped from −50 dBFS (0) to
/// −10 dBFS (1), the range a voice moves in. Not a measurement: a meter's input.
public enum AudioLevel {
    public static func of(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var rms: Float = 0
        if let data = buffer.floatChannelData {
            vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(frames))
        } else if let data = buffer.int16ChannelData {
            var samples = [Float](repeating: 0, count: frames)
            vDSP_vflt16(data[0], 1, &samples, 1, vDSP_Length(frames))
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frames))
            rms /= Float(Int16.max)
        }
        return scaled(rms)
    }

    /// −50 dBFS → 0, −10 dBFS → 1.
    public static func scaled(_ rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
