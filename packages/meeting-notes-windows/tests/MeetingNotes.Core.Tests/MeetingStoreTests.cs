using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

public class MeetingStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "mn-test-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    [Fact]
    public void WriteNote_then_List_round_trips_frontmatter()
    {
        var store = new MeetingStore(_dir);
        var date = new DateTime(2026, 6, 24, 9, 30, 0);
        store.WriteNote("Daily sync", date, "recordings/Daily sync", 1800, 3, "## Summary\n\nx", "**You:** hi", "0.1.0");

        var meetings = store.List();
        var m = Assert.Single(meetings);
        Assert.Equal("Daily sync", m.Title);
        Assert.Equal(date, m.Date);
        Assert.Equal(1800, m.DurationSeconds);
        Assert.Equal(3, m.SpeakerCount);
        Assert.Equal("0.1.0", m.AppVersion);
    }

    [Fact]
    public void List_orders_newest_first_by_frontmatter_date()
    {
        var store = new MeetingStore(_dir);
        store.WriteNote("older", new DateTime(2026, 6, 1, 8, 0, 0), "recordings/older", 0, 0, "", "", "v");
        store.WriteNote("newer", new DateTime(2026, 6, 20, 8, 0, 0), "recordings/newer", 0, 0, "", "", "v");

        var titles = store.List().Select(m => m.Title).ToArray();
        Assert.Equal(new[] { "newer", "older" }, titles);
    }

    [Fact]
    public void Sanitize_replaces_path_separators_and_colons()
    {
        Assert.Equal("a-b-c", MeetingStore.Sanitize(" a/b:c "));
    }

    [Fact]
    public void Sanitize_replaces_all_windows_forbidden_characters()
    {
        Assert.Equal("a-b-c-d-e-f-g-h", MeetingStore.Sanitize("a\\b*c?d\"e<f>g|h"));
    }

    [Fact]
    public void Rename_moves_file_and_refuses_conflicts()
    {
        var store = new MeetingStore(_dir);
        store.WriteNote("one", new DateTime(2026, 6, 1, 8, 0, 0), "recordings/one", 0, 0, "", "", "v");
        store.WriteNote("two", new DateTime(2026, 6, 2, 8, 0, 0), "recordings/two", 0, 0, "", "", "v");

        var one = store.List().First(m => m.Title == "one");
        Assert.Null(store.Rename(one, "two"));        // conflict
        var moved = store.Rename(one, "renamed");
        Assert.NotNull(moved);
        Assert.True(File.Exists(moved));
        Assert.DoesNotContain(store.List(), m => m.Title == "one");
    }

    [Fact]
    public void Delete_removes_note_and_unreferenced_audio()
    {
        var store = new MeetingStore(_dir);
        store.WriteNote("m", new DateTime(2026, 6, 1, 8, 0, 0), "recordings/m", 0, 0, "", "", "v");
        Directory.CreateDirectory(Path.Combine(_dir, "recordings"));
        var sysWav = Path.Combine(_dir, "recordings", "m.system.wav");
        File.WriteAllText(sysWav, "fake");

        store.Delete(store.List().Single());
        Assert.Empty(store.List());
        Assert.False(File.Exists(sysWav));
    }
}