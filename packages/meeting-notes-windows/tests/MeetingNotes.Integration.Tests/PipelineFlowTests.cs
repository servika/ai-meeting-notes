using MeetingNotes.Core;

namespace MeetingNotes.Integration.Tests;

/// <summary>
/// Whole-flow tests: a recording on disk goes through the real pipeline - launch
/// whisper, parse its JSON, merge the tracks, POST to the summary engine, write
/// the note, apply the audio-retention policy, rewrite the embeds - and the
/// assertions are on the vault that comes out the other end.
/// <para>
/// Only the model inference and the LLM are stubbed (a real child process and a
/// real HTTP server); every line of app logic in between is the shipping one.
/// </para>
/// </summary>
public class PipelineFlowTests : VaultFixture
{
    [Fact]
    public async Task A_recording_becomes_a_note_with_a_labeled_transcript_and_a_summary()
    {
        WriteTracks();
        var whisper = StubWhisper.Emitting(Dir,
            system: [(0, 2, "Hello from the other side.")],
            mic: [(3, 5, "Good to hear you.")]);
        using var summary = StubSummaryServer.Returning("## Short summary\nWe agreed to ship.");

        var result = await RunAsync(whisper, Options(summary));

        var note = await File.ReadAllTextAsync(result.NotePath);
        Assert.Contains("## Short summary\nWe agreed to ship.", note);
        // Both tracks are transcribed, labeled by side, and merged in time order.
        Assert.Matches(@"\[0:00\] \*\*Them:\*\* Hello from the other side\.", note);
        Assert.Matches(@"\[0:03\] \*\*You:\*\* Good to hear you\.", note);
        Assert.True(note.IndexOf("Them:", StringComparison.Ordinal) < note.IndexOf("You:", StringComparison.Ordinal));
        Assert.Equal("recordings/Meeting M", NoteFormat.FrontmatterValue("audio", note));
        Assert.Null(result.SummaryWarning);
    }

    [Fact]
    public async Task An_in_person_meeting_heard_on_both_tracks_is_not_transcribed_twice()
    {
        // Speakerphone/in-person: the mic and the loopback pick up the same words at
        // the same moment. The merged transcript must not show them doubled.
        WriteTracks();
        var both = new (double, double, string)[] { (0, 4, "let us go over the quarterly numbers before we finish") };
        var whisper = StubWhisper.Emitting(Dir, system: both, mic: both);
        using var summary = StubSummaryServer.Returning("## Short summary\nOnce.");

        var note = await File.ReadAllTextAsync((await RunAsync(whisper, Options(summary))).NotePath);

        var transcript = NoteFormat.ExtractTranscript(note);
        var occurrences = transcript.Split("quarterly numbers").Length - 1;
        Assert.Equal(1, occurrences);
    }

    [Fact]
    public async Task The_transcript_the_model_produced_reaches_the_summary_engine()
    {
        WriteTracks();
        var whisper = StubWhisper.Emitting(Dir, (0, 2, "Quarterly numbers look fine."));
        using var summary = StubSummaryServer.Returning("## Short summary\nDone.");

        await RunAsync(whisper, Options(summary));

        var prompt = Assert.Single(summary.Requests);
        Assert.Contains("Quarterly numbers look fine.", prompt);
        Assert.Contains("Short summary", prompt);
    }

    [Fact]
    public async Task Speech_on_only_one_track_still_produces_a_usable_note()
    {
        WriteTracks(mic: false);
        var whisper = StubWhisper.Emitting(Dir, (0, 2, "Only the remote side spoke."));
        using var summary = StubSummaryServer.Returning("## Short summary\nOne-sided.");

        var note = await File.ReadAllTextAsync((await RunAsync(whisper, Options(summary))).NotePath);

        Assert.Contains("**Them:** Only the remote side spoke.", note);
        Assert.DoesNotContain("**You:**", note);
    }

    [Fact]
    public async Task A_silent_recording_yields_a_note_and_never_calls_the_summary_engine()
    {
        WriteTracks();
        using var summary = StubSummaryServer.Returning("should not be used");

        var note = await File.ReadAllTextAsync((await RunAsync(StubWhisper.Silent(Dir), Options(summary))).NotePath);

        Assert.Contains("_(no speech detected)_", note);
        Assert.Empty(summary.Requests);
    }

    [Fact]
    public async Task A_failing_whisper_binary_surfaces_its_error_and_leaves_the_audio_alone()
    {
        WriteTracks();
        using var summary = StubSummaryServer.Returning("unused");

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            RunAsync(StubWhisper.Failing(Dir, "whisper: model load failed"), Options(summary)));

        Assert.Contains("model load failed", ex.Message);
        Assert.True(File.Exists(SystemTrack), "a failed transcription must not touch the recording");
        Assert.True(File.Exists(MicTrack));
    }

    [Fact]
    public async Task A_failing_summary_engine_still_saves_the_transcript_and_reports_the_failure()
    {
        WriteTracks();
        var whisper = StubWhisper.Emitting(Dir, (0, 2, "This must not be lost."));
        using var summary = StubSummaryServer.Failing("model not found");

        var result = await RunAsync(whisper, Options(summary));

        Assert.NotNull(result.SummaryWarning);
        Assert.Contains("This must not be lost.", await File.ReadAllTextAsync(result.NotePath));
    }

    [Fact]
    public async Task An_http_error_from_the_summary_engine_is_reported_not_thrown()
    {
        WriteTracks();
        var whisper = StubWhisper.Emitting(Dir, (0, 2, "Transcript survives."));
        using var summary = StubSummaryServer.Erroring(500);

        var result = await RunAsync(whisper, Options(summary));

        Assert.NotNull(result.SummaryWarning);
        Assert.Contains("Transcript survives.", await File.ReadAllTextAsync(result.NotePath));
    }

    [Fact]
    public async Task Long_meetings_are_summarized_by_map_reduce_in_several_calls()
    {
        WriteTracks();
        // Enough speech to cross the map-reduce threshold (90k chars).
        var line = string.Join(" ", Enumerable.Repeat("we discussed the migration plan in detail", 40));
        var segments = Enumerable.Range(0, 60)
            .Select(i => ((double)i * 3, i * 3 + 2.5, $"{line} part {i}"))
            .ToArray();
        var whisper = StubWhisper.Emitting(Dir, segments);
        using var summary = StubSummaryServer.Returning("## Short summary\nCombined.");

        var note = await File.ReadAllTextAsync((await RunAsync(whisper, Options(summary))).NotePath);

        Assert.True(summary.Requests.Count > 1, "a long transcript should map-reduce");
        Assert.Contains("## Short summary\nCombined.", note);
    }

    [Fact]
    public async Task Stopping_mid_run_leaves_the_recording_re_generatable()
    {
        WriteTracks();
        using var summary = StubSummaryServer.Returning("unused");
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            RunAsync(StubWhisper.Emitting(Dir, (0, 1, "x")), Options(summary), cts.Token));

        Assert.True(File.Exists(SystemTrack));
        Assert.True(File.Exists(MicTrack));
    }
}
