using MeetingNotes.Core;

namespace MeetingNotes.Integration.Tests;

/// <summary>
/// The record → transcribe → retention → re-generate lifecycle, end to end over a
/// real vault. This is where the 0.5.0 data-loss bug lived: a meeting that had
/// already been compressed, then re-generated or trimmed, lost both tracks.
/// <para>
/// The AAC encoder is Windows-only, so it's substituted with one that produces a
/// real (if not actually compressed) .m4a file; everything else - the policy, the
/// track lookup, the note rewrite, the second pipeline run - is production code.
/// </para>
/// </summary>
public class RetentionFlowTests : VaultFixture
{
    /// <summary>
    /// Stands in for Media Foundation, faithfully - including the sharp edge that
    /// caused the bug: an input it can't decode leaves it deleting the output path.
    /// (The shipping encoder has its own guards; this one deliberately doesn't, so
    /// these tests fail if the caller ever hands it a non-WAV again.)
    /// </summary>
    private static bool FakeEncoder(string wav, string m4a)
    {
        var bytes = File.Exists(wav) ? File.ReadAllBytes(wav) : [];
        var decodable = bytes.Length >= 12 && bytes[0] == (byte)'R' && bytes[1] == (byte)'I';
        if (!decodable)
        {
            try { if (File.Exists(m4a)) File.Delete(m4a); } catch { }
            return false;
        }
        File.WriteAllBytes(m4a, bytes.Take(bytes.Length / 4).ToArray());
        return true;
    }

    /// <summary>Run the retention step exactly as the app does after a pipeline run.</summary>
    private string? ApplyRetention(string policy, string? system = null, string? mic = null)
    {
        var ext = AudioRetention.Apply(system ?? SystemTrack, mic ?? MicTrack, policy, FakeEncoder);
        AudioRetention.RewriteNote(NotePath, AudioBase, ext);
        return ext;
    }

    private async Task<string> RecordAndTranscribeAsync(string policy)
    {
        WriteTracks();
        var whisper = StubWhisper.Emitting(Dir,
            system: [(0, 2, "Remote side speaking here.")],
            mic: [(3, 5, "Local side answering now.")]);
        using var summary = StubSummaryServer.Returning("## Short summary\nAll good.");
        await RunAsync(whisper, Options(summary, policy));
        ApplyRetention(policy);
        return await File.ReadAllTextAsync(NotePath);
    }

    [Fact]
    public async Task Keeping_the_original_leaves_wav_tracks_and_wav_links()
    {
        var note = await RecordAndTranscribeAsync("original");

        Assert.True(File.Exists(SystemTrack));
        Assert.True(File.Exists(MicTrack));
        Assert.Contains("![[Meeting M.system.wav]]", note);
    }

    [Fact]
    public async Task Compressing_swaps_both_the_files_and_the_links()
    {
        var note = await RecordAndTranscribeAsync("compressed");

        Assert.False(File.Exists(SystemTrack));
        Assert.False(File.Exists(MicTrack));
        Assert.True(File.Exists(SystemM4A));
        Assert.True(File.Exists(MicM4A));
        Assert.Contains("![[Meeting M.mic.m4a]]", note);
        Assert.Contains("![[Meeting M.system.m4a]]", note);
        Assert.DoesNotContain(".wav]]", note);
    }

    [Fact]
    public async Task Deleting_removes_the_audio_and_explains_itself_in_the_note()
    {
        var note = await RecordAndTranscribeAsync("delete");

        Assert.False(File.Exists(SystemTrack));
        Assert.False(File.Exists(MicTrack));
        Assert.False(File.Exists(SystemM4A));
        Assert.Contains("_Audio removed after transcription to save space._", note);
        // The transcript is what survives - that's the point of the policy.
        Assert.Contains("Remote side speaking here.", note);
    }

    [Fact]
    public async Task Re_generating_a_compressed_meeting_keeps_its_audio()
    {
        // The 0.5.0 regression, end to end: compress, then re-generate from whatever
        // tracks are now on disk, applying the policy a second time.
        await RecordAndTranscribeAsync("compressed");
        Assert.True(File.Exists(SystemM4A));

        var (system, mic) = AudioRetention.FindTracks(Dir, AudioBase);
        Assert.Equal(SystemM4A, system);
        Assert.Equal(MicM4A, mic);

        var whisper = StubWhisper.Emitting(Dir,
            system: [(0, 2, "Re-transcribed remote side.")],
            mic: [(3, 5, "Re-transcribed local side.")]);
        using var summary = StubSummaryServer.Returning("## Short summary\nRegenerated.");
        var pipeline = new MeetingPipeline(
            new WhisperTranscriber(whisper.ExePath), new Summarizer(new HttpClient()), new MeetingStore(Dir));
        await pipeline.ProcessAsync(system!, mic!, Title, MeetingDate, AudioBase, 60, 0,
            Options(summary, "compressed"), CancellationToken.None);
        ApplyRetention("compressed", system, mic);

        Assert.True(File.Exists(SystemM4A), "re-generating must not delete the compressed system track");
        Assert.True(File.Exists(MicM4A), "re-generating must not delete the compressed mic track");
        var note = await File.ReadAllTextAsync(NotePath);
        Assert.Contains("![[Meeting M.system.m4a]]", note);
        Assert.Contains("Re-transcribed remote side.", note);
    }

    [Fact]
    public async Task Trimming_a_compressed_meeting_keeps_its_audio()
    {
        await RecordAndTranscribeAsync("compressed");
        var (system, mic) = AudioRetention.FindTracks(Dir, AudioBase);

        // Trim updates the note's duration, then re-generates from the same tracks.
        AudioTrimmer.UpdateFrontmatterDuration(NotePath, 30);
        ApplyRetention("compressed", system, mic);

        Assert.True(File.Exists(SystemM4A));
        Assert.True(File.Exists(MicM4A));
        Assert.Equal("30", NoteFormat.FrontmatterValue("duration", await File.ReadAllTextAsync(NotePath)));
    }

    [Fact]
    public async Task Compressing_twice_in_a_row_is_harmless()
    {
        await RecordAndTranscribeAsync("compressed");
        var sizeBefore = new FileInfo(SystemM4A).Length;

        var (system, mic) = AudioRetention.FindTracks(Dir, AudioBase);
        Assert.Equal("m4a", ApplyRetention("compressed", system, mic));

        Assert.Equal(sizeBefore, new FileInfo(SystemM4A).Length);
    }

    [Fact]
    public async Task A_track_that_will_not_encode_leaves_the_note_pointing_at_the_wav()
    {
        WriteTracks();
        File.WriteAllText(MicTrack, "not audio at all");
        var whisper = StubWhisper.Emitting(Dir, (0, 2, "Something was said."));
        using var summary = StubSummaryServer.Returning("## Short summary\nFine.");
        await RunAsync(whisper, Options(summary, "compressed"));

        Assert.Equal("wav", ApplyRetention("compressed"));

        var note = await File.ReadAllTextAsync(NotePath);
        Assert.True(File.Exists(MicTrack), "the track we couldn't encode must be left alone");
        Assert.Contains("![[Meeting M.mic.wav]]", note);
    }

    [Fact]
    public async Task Audio_only_recordings_are_never_compressed_or_deleted()
    {
        // Transcription off: the audio *is* the content, so the app skips retention.
        WriteTracks();
        using var summary = StubSummaryServer.Returning("unused");
        var opts = Options(summary, "delete") with { Transcribe = false, Summarize = false };

        await RunAsync(StubWhisper.Silent(Dir), opts);

        // The app only runs retention when opts.Transcribe is true.
        if (opts.Transcribe) ApplyRetention(opts.AudioRetention);

        Assert.True(File.Exists(SystemTrack));
        Assert.True(File.Exists(MicTrack));
    }

    [Fact]
    public void Track_lookup_prefers_the_original_wav_over_a_leftover_m4a()
    {
        WriteTracks();
        File.WriteAllText(SystemM4A, "stale");
        File.WriteAllText(MicM4A, "stale");

        var (system, mic) = AudioRetention.FindTracks(Dir, AudioBase);

        Assert.Equal(SystemTrack, system);
        Assert.Equal(MicTrack, mic);
    }

    [Fact]
    public void Track_lookup_reports_missing_audio_rather_than_guessing()
    {
        var (system, mic) = AudioRetention.FindTracks(Dir, AudioBase);

        Assert.Null(system);
        Assert.Null(mic);
    }
}
