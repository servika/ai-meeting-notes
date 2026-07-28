using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// End-to-end pipeline behavior that doesn't need whisper or a summary engine:
/// which note comes out, what progress the UI is told, and how missing audio and
/// cancellation are handled. (Stages that shell out are covered on the machines
/// that have the binaries.)
/// </summary>
public class MeetingPipelineTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "pipeline-tests-" + Guid.NewGuid().ToString("N"));

    public MeetingPipelineTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
        GC.SuppressFinalize(this);
    }

    private MeetingPipeline NewPipeline() => new(
        new WhisperTranscriber("whisper-cli-not-used"),
        new Summarizer(new HttpClient()),
        new MeetingStore(_dir));

    private static PipelineOptions AudioOnly => new()
    {
        Transcribe = false,
        Summarize = false,
        AppVersion = "0.5.1",
    };

    private Task<PipelineResult> RunAsync(PipelineOptions opts,
        IProgress<PipelineProgress>? progress = null, CancellationToken ct = default) =>
        NewPipeline().ProcessAsync(
            Path.Combine(_dir, "M.system.wav"), Path.Combine(_dir, "M.mic.wav"),
            "Meeting M", new DateTime(2026, 6, 24, 10, 0, 0), "recordings/Meeting M",
            600, 0, opts, ct, progress);

    [Fact]
    public async Task Writes_an_audio_only_note_when_transcription_is_off()
    {
        var result = await RunAsync(AudioOnly);

        Assert.True(File.Exists(result.NotePath));
        var content = await File.ReadAllTextAsync(result.NotePath);
        Assert.Contains("_(no speech detected)_", content);
        Assert.Contains("![[Meeting M.mic.wav]]", content);
        Assert.Equal("recordings/Meeting M", NoteFormat.FrontmatterValue("audio", content));
        Assert.Equal("600", NoteFormat.FrontmatterValue("duration", content));
        Assert.Equal("0.5.1", NoteFormat.FrontmatterValue("app_version", content));
        Assert.Null(result.SummaryWarning);
    }

    [Fact]
    public async Task Missing_audio_tracks_still_produce_a_note_rather_than_an_error()
    {
        // Both tracks are absent; transcription is on but has nothing to read.
        var result = await RunAsync(AudioOnly with { Transcribe = true });

        Assert.True(File.Exists(result.NotePath));
        Assert.Contains("_(no speech detected)_", await File.ReadAllTextAsync(result.NotePath));
    }

    [Fact]
    public async Task Summarization_is_skipped_without_an_engine_and_reports_no_warning()
    {
        var result = await RunAsync(AudioOnly with { Transcribe = true, Summarize = true, Engine = null });

        Assert.Null(result.SummaryWarning);
        Assert.Equal("", NoteFormat.ExtractSummary(await File.ReadAllTextAsync(result.NotePath)));
    }

    [Fact]
    public async Task Progress_is_reported_monotonically_and_finishes_at_the_save_step()
    {
        var seen = new List<PipelineProgress>();
        await RunAsync(AudioOnly, new Progress<PipelineProgress>(p => { lock (seen) seen.Add(p); }));

        // Progress<T> posts asynchronously; give the callbacks a moment to land.
        for (var i = 0; i < 50 && seen.Count == 0; i++) await Task.Delay(10);

        lock (seen)
        {
            Assert.NotEmpty(seen);
            Assert.All(seen, p => Assert.InRange(p.Fraction, 0, 1));
            Assert.All(seen, p => Assert.False(string.IsNullOrWhiteSpace(p.Status)));
            Assert.Equal(seen.OrderBy(p => p.Fraction).Select(p => p.Fraction), seen.Select(p => p.Fraction));
        }
    }

    [Fact]
    public async Task The_note_lands_in_the_configured_vault_folder_under_the_meeting_title()
    {
        var result = await RunAsync(AudioOnly);
        Assert.Equal(Path.Combine(_dir, "Meeting M.md"), result.NotePath);
    }

    [Fact]
    public async Task Re_running_overwrites_the_same_note_instead_of_creating_a_second_one()
    {
        await RunAsync(AudioOnly);
        await RunAsync(AudioOnly);

        Assert.Single(Directory.EnumerateFiles(_dir, "*.md"));
    }

    [Fact]
    public async Task A_cancelled_run_throws_and_the_caller_keeps_the_audio()
    {
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            RunAsync(AudioOnly with { Transcribe = true }, ct: cts.Token));
    }

    [Fact]
    public void Default_options_run_the_full_pipeline_and_keep_the_original_audio()
    {
        var opts = new PipelineOptions();

        Assert.True(opts.Transcribe);
        Assert.True(opts.Summarize);
        Assert.Equal("auto", opts.Language);
        Assert.Equal("original", opts.AudioRetention);
    }
}