using MeetingNotes.Core;
using NAudio.MediaFoundation;
using NAudio.Wave;

namespace MeetingNotes.Audio;

/// <summary>
/// Compresses WAV recordings to AAC M4A using Windows Media Foundation.
/// Port of macOS RecordingController+AudioRetention.swift.
/// </summary>
public static class AudioCompressor
{
    /// <summary>
    /// Apply the audio retention policy to both tracks after transcription.
    /// Returns the resulting file extension ("wav", "m4a") or null if deleted.
    /// The policy itself lives in <see cref="AudioRetention"/> (portable, and
    /// therefore testable without Media Foundation); this supplies the encoder.
    /// </summary>
    public static string? ApplyRetention(string systemWav, string micWav, string policy) =>
        AudioRetention.Apply(systemWav, micWav, policy, CompressToM4A);

    /// <summary>
    /// Compress a WAV file to AAC M4A at speech-quality bitrate.
    /// Returns true on success.
    /// </summary>
    public static bool CompressToM4A(string wavPath, string m4aPath)
    {
        // Only the output we created ourselves may be cleaned up on failure - never
        // a file that was already there, which could be the source recording.
        var preexisting = File.Exists(m4aPath);
        try
        {
            if (SamePath(wavPath, m4aPath)) return false;
            MediaFoundationApi.Startup();
            using var reader = new WaveFileReader(wavPath);
            MediaFoundationEncoder.EncodeToAac(reader, m4aPath);
            return File.Exists(m4aPath) && new FileInfo(m4aPath).Length > 0;
        }
        catch
        {
            if (!preexisting) TryDelete(m4aPath);
            return false;
        }
    }

    private static bool SamePath(string a, string b) =>
        string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}