import AVFAudio
import Testing
import VoiceKit

/// The meter's scale (EFFICIENCY.md E8 revision): silence reads 0, a normal voice most
/// of the way up, a shout at the top, whatever the sample format.
@Suite("Audio level")
struct AudioLevelTests {
    @Test("silence, a voice-level tone and a full-scale tone, in float and in 16-bit")
    func scale() throws {
        #expect(AudioLevel.scaled(0) == 0)
        #expect(AudioLevel.scaled(1) == 1)
        let voice = AudioLevel.scaled(0.05)  // about −26 dBFS
        #expect(voice > 0.5 && voice < 0.7)

        let float = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: float, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData![0][index] = index.isMultiple(of: 2) ? 0.05 : -0.05 }
        #expect(abs(AudioLevel.of(buffer) - voice) < 0.01)

        let int16 = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let quantized = try #require(AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: 1_600))
        quantized.frameLength = 1_600
        for index in 0..<1_600 { quantized.int16ChannelData![0][index] = index.isMultiple(of: 2) ? 1_638 : -1_638 }
        #expect(abs(AudioLevel.of(quantized) - voice) < 0.01)
    }
}
