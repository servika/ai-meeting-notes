using MeetingNotes.Core;

namespace MeetingNotes.Integration.Tests;

/// <summary>
/// A throwaway vault with a real recording in it, plus the wiring to run the
/// production pipeline over it. Shared by the flow and retention suites.
/// </summary>
public abstract class VaultFixture : IDisposable
{
    protected string Dir { get; } = Path.Combine(
        Path.GetTempPath(), "integration-" + Guid.NewGuid().ToString("N"));

    protected const string Title = "Meeting M";
    protected const string AudioBase = "recordings/Meeting M";
    protected static readonly DateTime MeetingDate = new(2026, 6, 24, 10, 0, 0);

    protected string RecordingsDir => Path.Combine(Dir, "recordings");
    protected string SystemTrack => Path.Combine(RecordingsDir, "Meeting M.system.wav");
    protected string MicTrack => Path.Combine(RecordingsDir, "Meeting M.mic.wav");
    protected string SystemM4A => Path.Combine(RecordingsDir, "Meeting M.system.m4a");
    protected string MicM4A => Path.Combine(RecordingsDir, "Meeting M.mic.m4a");
    protected string NotePath => Path.Combine(Dir, Title + ".md");

    /// <summary>A model file only has to exist - the stub CLI never reads it.</summary>
    protected string ModelPath { get; }

    protected VaultFixture()
    {
        Directory.CreateDirectory(RecordingsDir);
        ModelPath = Path.Combine(Dir, "ggml-stub.bin");
        File.WriteAllText(ModelPath, "stub model");
    }

    public void Dispose()
    {
        try { Directory.Delete(Dir, recursive: true); } catch { }
        GC.SuppressFinalize(this);
    }

    /// <summary>Write real (short) 16 kHz mono WAV tracks for the meeting.</summary>
    protected void WriteTracks(bool system = true, bool mic = true, double seconds = 1)
    {
        if (system) WriteWav(SystemTrack, seconds);
        if (mic) WriteWav(MicTrack, seconds);
    }

    protected static void WriteWav(string path, double seconds = 1, int sampleRate = 16000)
    {
        var samples = (int)(seconds * sampleRate);
        using var w = new BinaryWriter(File.Create(path));
        w.Write("RIFF"u8);
        w.Write(36 + samples * 2);
        w.Write("WAVE"u8);
        w.Write("fmt "u8);
        w.Write(16);
        w.Write((short)1);
        w.Write((short)1);
        w.Write(sampleRate);
        w.Write(sampleRate * 2);
        w.Write((short)2);
        w.Write((short)16);
        w.Write("data"u8);
        w.Write(samples * 2);
        for (var i = 0; i < samples; i++)
            w.Write((short)(Math.Sin(i * 2 * Math.PI * 440 / sampleRate) * 0.5 * short.MaxValue));
    }

    protected PipelineOptions Options(StubSummaryServer summary, string retention = "original") => new()
    {
        Transcribe = true,
        Summarize = true,
        Language = "en",
        WhisperModelPath = ModelPath,
        SummaryPrompt = SummaryPrompts.Default,
        Engine = new SummaryEngine.Ollama(summary.Url, "stub-model"),
        AppVersion = "0.5.1",
        AudioRetention = retention,
    };

    /// <summary>Run the real pipeline over this vault's recording.</summary>
    protected Task<PipelineResult> RunAsync(
        StubWhisper whisper, PipelineOptions opts, CancellationToken ct = default,
        IProgress<PipelineProgress>? progress = null)
    {
        var pipeline = new MeetingPipeline(
            new WhisperTranscriber(whisper.ExePath),
            new Summarizer(new HttpClient()),
            new MeetingStore(Dir));
        return pipeline.ProcessAsync(
            SystemTrack, MicTrack, Title, MeetingDate, AudioBase,
            durationSeconds: 60, speakerCount: 0, opts, ct, progress);
    }
}
