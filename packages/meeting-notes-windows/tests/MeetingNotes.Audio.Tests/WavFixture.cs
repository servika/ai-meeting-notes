namespace MeetingNotes.Audio.Tests;

/// <summary>
/// A scratch directory plus a writer for real 16 kHz mono 16-bit PCM WAVs - the
/// format MeetingRecorder produces. The audio tests operate on actual files
/// because what they assert is which files survive on disk.
/// </summary>
public abstract class WavFixture : IDisposable
{
    protected string Dir { get; } = Path.Combine(
        Path.GetTempPath(), "audio-tests-" + Guid.NewGuid().ToString("N"));

    protected WavFixture() => Directory.CreateDirectory(Dir);

    public void Dispose()
    {
        try { Directory.Delete(Dir, recursive: true); } catch { }
        GC.SuppressFinalize(this);
    }

    protected string Path_(string name) => Path.Combine(Dir, name);

    /// <summary>Write a tone (or silence, at amplitude 0) of the given length.</summary>
    protected string WriteWav(string name, double seconds = 1.0, double amplitude = 0.5, int sampleRate = 16000)
    {
        var path = Path_(name);
        var samples = (int)(seconds * sampleRate);
        using var w = new BinaryWriter(File.Create(path));
        w.Write("RIFF"u8);
        w.Write(36 + samples * 2);
        w.Write("WAVE"u8);
        w.Write("fmt "u8);
        w.Write(16);
        w.Write((short)1);  // PCM
        w.Write((short)1);  // mono
        w.Write(sampleRate);
        w.Write(sampleRate * 2);
        w.Write((short)2);
        w.Write((short)16);
        w.Write("data"u8);
        w.Write(samples * 2);
        for (var i = 0; i < samples; i++)
            w.Write((short)(Math.Sin(i * 2 * Math.PI * 440 / sampleRate) * amplitude * short.MaxValue));
        return path;
    }
}