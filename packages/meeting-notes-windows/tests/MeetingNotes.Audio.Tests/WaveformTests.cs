using MeetingNotes.Audio;

namespace MeetingNotes.Audio.Tests;

/// <summary>
/// The loudness envelope drawn in the Trim window: it has to normalize to the
/// loudest moment, combine the two tracks, and degrade quietly when a track is
/// missing or unreadable (the window still has to open).
/// </summary>
public class WaveformTests : WavFixture
{
    [Fact]
    public void Compute_returns_one_value_per_bucket_normalized_to_the_peak()
    {
        var wav = WriteWav("tone.wav", seconds: 2);

        var env = Waveform.Compute([wav], 32);

        Assert.Equal(32, env.Length);
        Assert.All(env, v => Assert.InRange(v, 0f, 1f));
        Assert.Equal(1f, env.Max(), precision: 3);
    }

    [Fact]
    public void A_quiet_track_reads_as_quiet_relative_to_a_loud_one()
    {
        var loud = WriteWav("loud.wav", seconds: 1, amplitude: 0.9);
        var quiet = WriteWav("quiet.wav", seconds: 1, amplitude: 0.001);

        // Combined, the quiet track contributes nothing above the loud one.
        var combined = Waveform.Compute([loud, quiet], 16);
        var quietOnly = Waveform.Compute([quiet], 16);

        Assert.True(combined.Average() > 0.5f);
        // Normalized against itself, a uniform quiet track still peaks at 1 - what
        // matters is that it never raises the combined envelope.
        Assert.Equal(1f, quietOnly.Max(), precision: 3);
        Assert.Equal(Waveform.Compute([loud], 16), combined);
    }

    [Fact]
    public void Silence_after_the_meeting_shows_up_as_quiet_buckets()
    {
        // Loud first half, silent second half, concatenated into one track.
        var path = Path_("half-silent.wav");
        WriteHalfSilentWav(path);

        var env = Waveform.Compute([path], 16);

        Assert.True(env.Take(6).Average() > Waveform.QuietLevel);
        Assert.True(env.Skip(10).All(v => v < Waveform.QuietLevel));
    }

    [Fact]
    public void Missing_and_unreadable_tracks_yield_an_empty_envelope()
    {
        Assert.Empty(Waveform.Compute([Path_("nope.wav")], 16));

        var junk = Path_("junk.wav");
        File.WriteAllText(junk, "not audio at all");
        Assert.Empty(Waveform.Compute([junk], 16));
    }

    [Fact]
    public void A_readable_track_still_renders_when_its_sibling_is_missing()
    {
        var wav = WriteWav("one.wav");

        var env = Waveform.Compute([Path_("gone.wav"), wav], 16);

        Assert.Equal(16, env.Length);
        Assert.Equal(1f, env.Max(), precision: 3);
    }

    [Fact]
    public void A_silent_recording_has_no_envelope_to_draw()
    {
        var silent = WriteWav("silent.wav", amplitude: 0);

        Assert.Empty(Waveform.Compute([silent], 16));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void A_non_positive_bucket_count_is_rejected(int buckets)
    {
        Assert.Empty(Waveform.Compute([WriteWav("tone.wav")], buckets));
    }

    [Fact]
    public void No_tracks_at_all_yields_an_empty_envelope()
    {
        Assert.Empty(Waveform.Compute([], 16));
    }

    /// <summary>One second of tone followed by one second of digital silence.</summary>
    private static void WriteHalfSilentWav(string path, int sampleRate = 16000)
    {
        const int seconds = 2;
        var samples = sampleRate * seconds;
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
        {
            var loud = i < sampleRate;
            w.Write(loud ? (short)(Math.Sin(i * 2 * Math.PI * 440 / sampleRate) * 0.8 * short.MaxValue) : (short)0);
        }
    }
}