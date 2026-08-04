using System.Text;

namespace MeetingNotes.Core;

/// <summary>
/// Opt-in troubleshooting log. Off by default - it only starts writing once the
/// user ticks "Write diagnostic log" in Settings, so nothing lands on disk for
/// people who never hit a problem.
///
/// Every call is best-effort: a logging failure must never take down a recording,
/// so all IO errors are swallowed. The file self-rotates at <see cref="MaxBytes"/>
/// into a single `.1` backup, which bounds it at ~4 MB no matter how long the app
/// runs.
/// </summary>
public static class DiagnosticLog
{
    private const long MaxBytes = 2 * 1024 * 1024;
    private static readonly object Gate = new();
    private static string? _pathOverride;

    /// <summary>Set from settings; when false, <see cref="Write"/> is a no-op.</summary>
    public static bool Enabled { get; set; }

    /// <summary>Folder holding the log and its rotated backup.</summary>
    public static string Folder => _pathOverride ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "MeetingNotes", "logs");

    public static string LogPath => Path.Combine(Folder, "meeting-notes.log");

    /// <summary>Redirect the log elsewhere (tests). Null restores the default folder.</summary>
    public static void UseFolder(string? folder) => _pathOverride = folder;

    /// <summary>Append one timestamped line. Silent when logging is off.</summary>
    public static void Write(string message)
    {
        if (!Enabled) return;
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}  {message}{Environment.NewLine}";
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Folder);
                Rotate();
                File.AppendAllText(LogPath, line, Encoding.UTF8);
            }
        }
        catch { /* logging must never break the app */ }
    }

    /// <summary>Log an exception with its type, message and stack.</summary>
    public static void Exception(string context, Exception ex) =>
        Write($"ERROR {context}: {ex.GetType().Name}: {ex.Message}\n{ex.StackTrace}");

    /// <summary>Header written when logging is switched on, so a shared log is self-describing.</summary>
    public static void WriteSessionHeader(string appVersion)
    {
        if (!Enabled) return;
        Write($"=== AI Meeting Notes v{appVersion} | {Environment.OSVersion} | "
            + $"{Environment.ProcessorCount} cores | log started ===");
    }

    /// <summary>Delete the log and its backup.</summary>
    public static void Clear()
    {
        try
        {
            lock (Gate)
            {
                if (File.Exists(LogPath)) File.Delete(LogPath);
                if (File.Exists(LogPath + ".1")) File.Delete(LogPath + ".1");
            }
        }
        catch { /* best effort */ }
    }

    // Caller holds Gate.
    private static void Rotate()
    {
        var info = new FileInfo(LogPath);
        if (!info.Exists || info.Length < MaxBytes) return;
        var backup = LogPath + ".1";
        if (File.Exists(backup)) File.Delete(backup);
        File.Move(LogPath, backup);
    }
}