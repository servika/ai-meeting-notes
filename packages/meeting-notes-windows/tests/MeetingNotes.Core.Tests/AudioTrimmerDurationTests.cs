using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// Reading a recording's length and keeping the note's <c>duration:</c> honest -
/// re-generate trusts that value, so a stale one silently mis-estimates the run.
/// </summary>
public class AudioTrimmerDurationTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "trim-duration-tests-" + Guid.NewGuid().ToString("N"));

    public AudioTrimmerDurationTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
        GC.SuppressFinalize(this);
    }

    /// <summary>Write a 16 kHz mono 16-bit PCM WAV of the given length.</summary>
    private string WriteWav(string name, double seconds, int sampleRate = 16000)
    {
        var path = Path.Combine(_dir, name);
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
        for (var i = 0; i < samples; i++) w.Write((short)(i % 1000));
        return path;
    }

    [Fact]
    public void GetDurationSeconds_reads_the_length_from_the_header()
    {
        Assert.Equal(2.5, AudioTrimmer.GetDurationSeconds(WriteWav("a.wav", 2.5)), precision: 3);
    }

    [Fact]
    public void GetDurationSeconds_honors_the_sample_rate()
    {
        Assert.Equal(1.0, AudioTrimmer.GetDurationSeconds(WriteWav("b.wav", 1.0, 44100)), precision: 3);
    }

    [Fact]
    public void GetDurationSeconds_returns_zero_for_a_missing_or_non_wav_file()
    {
        Assert.Equal(0, AudioTrimmer.GetDurationSeconds(Path.Combine(_dir, "nope.wav")));

        var junk = Path.Combine(_dir, "junk.wav");
        File.WriteAllText(junk, "not audio at all");
        Assert.Equal(0, AudioTrimmer.GetDurationSeconds(junk));
    }

    [Fact]
    public void Duration_shrinks_after_a_trim()
    {
        var path = WriteWav("c.wav", 4);

        Assert.True(AudioTrimmer.TrimWav(path, 1, 3));
        Assert.Equal(2.0, AudioTrimmer.GetDurationSeconds(path), precision: 2);
    }

    [Fact]
    public void UpdateFrontmatterDuration_rewrites_only_that_line()
    {
        var note = Path.Combine(_dir, "note.md");
        File.WriteAllText(note, NoteFormat.BuildNote(
            "T", "2026-06-24 10-00-00", "recordings/T", 3600, 0, "", "x", "0.5.1"));

        AudioTrimmer.UpdateFrontmatterDuration(note, 95);

        var content = File.ReadAllText(note);
        Assert.Equal("95", NoteFormat.FrontmatterValue("duration", content));
        Assert.Equal("recordings/T", NoteFormat.FrontmatterValue("audio", content));
        Assert.Contains("## Transcript", content);
    }

    [Fact]
    public void UpdateFrontmatterDuration_leaves_a_note_without_a_duration_line_alone()
    {
        var note = Path.Combine(_dir, "note.md");
        var original = NoteFormat.BuildNote("T", "D", "recordings/T", 0, 0, "", "x", "0.5.1");
        File.WriteAllText(note, original);

        AudioTrimmer.UpdateFrontmatterDuration(note, 95);

        Assert.Equal(original, File.ReadAllText(note));
    }

    [Fact]
    public void UpdateFrontmatterDuration_ignores_a_missing_file_or_missing_frontmatter()
    {
        AudioTrimmer.UpdateFrontmatterDuration(Path.Combine(_dir, "gone.md"), 10); // must not throw

        var plain = Path.Combine(_dir, "plain.md");
        File.WriteAllText(plain, "# No frontmatter\n\nduration: 1\n");
        AudioTrimmer.UpdateFrontmatterDuration(plain, 95);
        Assert.Equal("# No frontmatter\n\nduration: 1\n", File.ReadAllText(plain));
    }

    [Fact]
    public void UpdateFrontmatterDuration_does_not_touch_a_body_line_after_the_block()
    {
        var note = Path.Combine(_dir, "note.md");
        File.WriteAllText(note, "---\ntype: meeting\n---\n\nduration: 1\n");

        AudioTrimmer.UpdateFrontmatterDuration(note, 95);

        Assert.Equal("---\ntype: meeting\n---\n\nduration: 1\n", File.ReadAllText(note));
    }
}