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
    /// </summary>
    public static string? ApplyRetention(string systemWav, string micWav, string policy)
    {
        switch (policy)
        {
            case "delete":
                TryDelete(systemWav);
                TryDelete(micWav);
                return null;

            case "compressed":
                var allOk = true;
                foreach (var wav in new[] { systemWav, micWav })
                {
                    if (!File.Exists(wav)) continue;
                    var m4a = Path.ChangeExtension(wav, ".m4a");
                    if (CompressToM4A(wav, m4a))
                        TryDelete(wav);
                    else
                        allOk = false;
                }
                return allOk ? "m4a" : "wav";

            default: // "original"
                return "wav";
        }
    }

    /// <summary>
    /// Compress a WAV file to AAC M4A at speech-quality bitrate.
    /// Returns true on success.
    /// </summary>
    public static bool CompressToM4A(string wavPath, string m4aPath)
    {
        try
        {
            MediaFoundationApi.Startup();
            using var reader = new WaveFileReader(wavPath);
            MediaFoundationEncoder.EncodeToAac(reader, m4aPath);
            return File.Exists(m4aPath) && new FileInfo(m4aPath).Length > 0;
        }
        catch
        {
            TryDelete(m4aPath);
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
