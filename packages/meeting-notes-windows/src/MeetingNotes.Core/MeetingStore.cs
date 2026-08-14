using System.Globalization;

namespace MeetingNotes.Core;

/// <summary>A meeting note on disk, with the bits parsed from its frontmatter.</summary>
public sealed record Meeting(
    string Path,
    string Title,
    DateTime Date,
    int DurationSeconds,
    string AppVersion,
    int SpeakerCount);

/// <summary>
/// Reads, writes, lists, renames, and deletes meeting notes (`*.md`) in the
/// configured Obsidian vault folder. C# port of the macOS MeetingStore +
/// RecordingController note I/O; uses <see cref="NoteFormat"/> for the body so
/// notes stay byte-compatible across platforms.
/// </summary>
public sealed class MeetingStore(string meetingsFolder)
{
    // Recording-timestamp format used in note frontmatter (`date:`).
    private const string DateFormat = "yyyy-MM-dd HH-mm-ss";

    /// <summary>Write (or overwrite) a meeting note named <paramref name="title"/>.md. Returns its path.</summary>
    public string WriteNote(
        string title, DateTime date, string audioBase, int durationSeconds,
        int speakerCount, string summary, string transcript, string appVersion,
        string audioExt = "wav", string summaryModel = "")
    {
        Directory.CreateDirectory(meetingsFolder);
        var body = NoteFormat.BuildNote(
            title, date.ToString(DateFormat, CultureInfo.InvariantCulture),
            audioBase, durationSeconds, speakerCount, summary, transcript, appVersion,
            audioExt, summaryModel: summaryModel);
        var path = Path.Combine(meetingsFolder, Sanitize(title) + ".md");
        File.WriteAllText(path, body);
        return path;
    }

    /// <summary>List meeting notes, newest first by the note's own <c>date:</c> frontmatter.</summary>
    public List<Meeting> List()
    {
        if (!Directory.Exists(meetingsFolder)) return [];
        var meetings = new List<Meeting>();
        foreach (var path in Directory.EnumerateFiles(meetingsFolder, "*.md"))
        {
            var content = File.ReadAllText(path);
            var title = Path.GetFileNameWithoutExtension(path);
            var dur = ParseInt(NoteFormat.FrontmatterValue("duration", content));
            var ver = NoteFormat.FrontmatterValue("app_version", content) ?? "";
            var speakers = ParseInt(NoteFormat.FrontmatterValue("speakers", content));
            var date = ParseDate(NoteFormat.FrontmatterValue("date", content))
                       ?? File.GetLastWriteTime(path);
            meetings.Add(new Meeting(path, title, date, dur, ver, speakers));
        }
        return meetings.OrderByDescending(m => m.Date).ToList();
    }

    /// <summary>Rename a note's file. Returns the new path, or null on no-op/conflict.</summary>
    public string? Rename(Meeting meeting, string newName)
    {
        var safe = Sanitize(newName);
        if (safe.Length == 0 || safe == meeting.Title) return null;
        var dir = Path.GetDirectoryName(meeting.Path)!;
        var dest = Path.Combine(dir, safe + ".md");
        if (File.Exists(dest)) return null;
        File.Move(meeting.Path, dest);
        // Keep the note's "# H1" heading in step with the filename (mirrors the
        // macOS rename fix) so the old title doesn't linger in the body or leak
        // into a later re-generation.
        try
        {
            var content = File.ReadAllText(dest);
            var updated = NoteFormat.ReplaceFirstHeading(content, safe);
            if (updated != content) File.WriteAllText(dest, updated);
        }
        catch { /* best effort - the rename itself already succeeded */ }
        return dest;
    }

    /// <summary>Delete a note and its linked audio tracks (unless another note still references them).</summary>
    public void Delete(Meeting meeting)
    {
        var dir = Path.GetDirectoryName(meeting.Path)!;
        var content = File.Exists(meeting.Path) ? File.ReadAllText(meeting.Path) : "";
        var audioBase = NoteFormat.FrontmatterValue("audio", content) ?? $"recordings/{meeting.Title}";
        TryDelete(meeting.Path);
        if (FindNoteByAudio(audioBase, dir) is null)
            foreach (var ext in new[] { "system.wav", "mic.wav", "system.m4a", "mic.m4a" })
                TryDelete(Path.Combine(dir, NormalizeRelative(audioBase) + "." + ext));
    }

    /// <summary>Find a note in <paramref name="dir"/> that links the given audio base, if any.</summary>
    internal static string? FindNoteByAudio(string audioBase, string dir)
    {
        if (!Directory.Exists(dir)) return null;
        foreach (var path in Directory.EnumerateFiles(dir, "*.md"))
            if (NoteFormat.FrontmatterValue("audio", File.ReadAllText(path)) == audioBase)
                return path;
        return null;
    }

    /// <summary>
    /// Sanitize a title into a safe note filename stem. Replaces all characters
    /// forbidden on Windows (<c>/ \ : * ? " &lt; &gt; |</c>) with dashes and
    /// strips leading/trailing whitespace.
    /// </summary>
    internal static string Sanitize(string name)
    {
        var s = name;
        foreach (var c in new[] { '/', '\\', ':', '*', '?', '"', '<', '>', '|' })
            s = s.Replace(c, '-');
        return s.Trim();
    }

    private static string NormalizeRelative(string p) => p.Replace('/', Path.DirectorySeparatorChar);

    private static int ParseInt(string? s) =>
        int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;

    private static DateTime? ParseDate(string? s) =>
        DateTime.TryParseExact(s, DateFormat, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
            ? d : null;

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }
}