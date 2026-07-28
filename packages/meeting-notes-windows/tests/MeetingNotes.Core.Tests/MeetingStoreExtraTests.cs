using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// Vault edge cases around <see cref="MeetingStore"/>: an unconfigured folder,
/// compressed-audio notes, and the shared-audio guard that keeps a recording
/// alive while any note still links it.
/// </summary>
public class MeetingStoreExtraTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "store-extra-tests-" + Guid.NewGuid().ToString("N"));

    public MeetingStoreExtraTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
        GC.SuppressFinalize(this);
    }

    private MeetingStore Store => new(_dir);

    private void TouchAudio(string relativeBase, params string[] suffixes)
    {
        var full = Path.Combine(_dir, relativeBase.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        foreach (var s in suffixes) File.WriteAllText(full + "." + s, "audio");
    }

    [Fact]
    public void Listing_a_folder_that_does_not_exist_yet_yields_nothing()
    {
        Assert.Empty(new MeetingStore(Path.Combine(_dir, "not-created")).List());
    }

    [Fact]
    public void WriteNote_creates_the_meetings_folder_on_demand()
    {
        var store = new MeetingStore(Path.Combine(_dir, "Meetings"));
        var path = store.WriteNote("M", new DateTime(2026, 6, 24, 10, 0, 0),
            "recordings/M", 60, 0, "", "x", "0.5.1");

        Assert.True(File.Exists(path));
    }

    [Fact]
    public void WriteNote_can_link_compressed_audio()
    {
        var path = Store.WriteNote("M", new DateTime(2026, 6, 24, 10, 0, 0),
            "recordings/M", 60, 0, "", "x", "0.5.1", audioExt: "m4a");

        Assert.Contains("![[M.mic.m4a]]", File.ReadAllText(path));
    }

    [Fact]
    public void A_note_with_unparsable_frontmatter_still_lists_with_safe_defaults()
    {
        File.WriteAllText(Path.Combine(_dir, "Odd.md"),
            "---\ntype: meeting\nduration: soon\ndate: yesterday\n---\n\n# Odd\n");

        var m = Assert.Single(Store.List());
        Assert.Equal("Odd", m.Title);
        Assert.Equal(0, m.DurationSeconds);
        Assert.Equal(0, m.SpeakerCount);
        Assert.Equal("", m.AppVersion);
    }

    [Fact]
    public void Delete_removes_compressed_tracks_too()
    {
        var path = Store.WriteNote("M", new DateTime(2026, 6, 24, 10, 0, 0),
            "recordings/M", 60, 0, "", "x", "0.5.1", audioExt: "m4a");
        TouchAudio("recordings/M", "system.m4a", "mic.m4a");

        Store.Delete(Store.List().Single(m => m.Path == path));

        Assert.False(File.Exists(Path.Combine(_dir, "recordings", "M.system.m4a")));
        Assert.False(File.Exists(Path.Combine(_dir, "recordings", "M.mic.m4a")));
    }

    [Fact]
    public void Delete_keeps_audio_that_another_note_still_links()
    {
        Store.WriteNote("A", new DateTime(2026, 6, 24, 10, 0, 0), "recordings/shared", 60, 0, "", "x", "0.5.1");
        Store.WriteNote("B", new DateTime(2026, 6, 24, 11, 0, 0), "recordings/shared", 60, 0, "", "x", "0.5.1");
        TouchAudio("recordings/shared", "system.wav", "mic.wav");

        Store.Delete(Store.List().Single(m => m.Title == "A"));

        Assert.True(File.Exists(Path.Combine(_dir, "recordings", "shared.system.wav")),
            "audio still referenced by note B must survive");
    }

    [Fact]
    public void Rename_keeps_the_note_findable_by_its_audio_link()
    {
        var path = Store.WriteNote("M", new DateTime(2026, 6, 24, 10, 0, 0),
            "recordings/M", 60, 0, "", "x", "0.5.1");
        var renamed = Store.Rename(Store.List().Single(m => m.Path == path), "Budget review");

        Assert.NotNull(renamed);
        Assert.Equal(renamed, MeetingStore.FindNoteByAudio("recordings/M", _dir));
    }

    [Fact]
    public void Sanitize_trims_surrounding_whitespace()
    {
        Assert.Equal("Meeting", MeetingStore.Sanitize("  Meeting  "));
    }
}