using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// The log is opt-in and must never throw: it runs inside audio callbacks and the
/// stop path, where an exception would cost the user their recording.
/// </summary>
public sealed class DiagnosticLogTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "mn-log-tests-" + Guid.NewGuid().ToString("N"));

    public DiagnosticLogTests()
    {
        DiagnosticLog.UseFolder(_dir);
        DiagnosticLog.Enabled = false;
    }

    public void Dispose()
    {
        DiagnosticLog.Enabled = false;
        DiagnosticLog.UseFolder(null);
        try { if (Directory.Exists(_dir)) Directory.Delete(_dir, true); } catch { }
    }

    [Fact]
    public void WritesNothingWhenDisabled()
    {
        DiagnosticLog.Write("should not appear");
        DiagnosticLog.WriteSessionHeader("1.2.3");
        Assert.False(File.Exists(DiagnosticLog.LogPath));
        Assert.False(Directory.Exists(_dir));
    }

    [Fact]
    public void AppendsTimestampedLinesWhenEnabled()
    {
        DiagnosticLog.Enabled = true;
        DiagnosticLog.Write("first");
        DiagnosticLog.Write("second");

        var lines = File.ReadAllLines(DiagnosticLog.LogPath);
        Assert.Equal(2, lines.Length);
        Assert.EndsWith("first", lines[0]);
        Assert.EndsWith("second", lines[1]);
        // Leading timestamp, e.g. "2026-08-04 11:22:33.444  first".
        Assert.Matches(@"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}  ", lines[0]);
    }

    [Fact]
    public void SessionHeaderNamesTheBuild()
    {
        DiagnosticLog.Enabled = true;
        DiagnosticLog.WriteSessionHeader("0.6.0");
        Assert.Contains("v0.6.0", File.ReadAllText(DiagnosticLog.LogPath));
    }

    [Fact]
    public void ExceptionLogsTypeMessageAndContext()
    {
        DiagnosticLog.Enabled = true;
        DiagnosticLog.Exception("capture: mic restart", new InvalidOperationException("device gone"));

        var text = File.ReadAllText(DiagnosticLog.LogPath);
        Assert.Contains("capture: mic restart", text);
        Assert.Contains(nameof(InvalidOperationException), text);
        Assert.Contains("device gone", text);
    }

    [Fact]
    public void RotatesOnceOverTheSizeCapAndKeepsOneBackup()
    {
        DiagnosticLog.Enabled = true;
        var line = new string('x', 4096);
        // 2 MB cap; write past it so a rotation is forced, then some more.
        for (var i = 0; i < 700; i++) DiagnosticLog.Write(line);

        Assert.True(File.Exists(DiagnosticLog.LogPath));
        Assert.True(File.Exists(DiagnosticLog.LogPath + ".1"));
        // Exactly the live log and one backup - rotation never accumulates files.
        Assert.Equal(2, Directory.GetFiles(_dir).Length);
        Assert.True(new FileInfo(DiagnosticLog.LogPath).Length < 2 * 1024 * 1024);
    }

    [Fact]
    public void ClearRemovesLogAndBackup()
    {
        DiagnosticLog.Enabled = true;
        DiagnosticLog.Write("something");
        File.WriteAllText(DiagnosticLog.LogPath + ".1", "old");

        DiagnosticLog.Clear();
        Assert.False(File.Exists(DiagnosticLog.LogPath));
        Assert.False(File.Exists(DiagnosticLog.LogPath + ".1"));
    }

    [Fact]
    public void SurvivesAnUnwritableFolder()
    {
        DiagnosticLog.Enabled = true;
        // A path that cannot be a directory (it is an existing file) - Write must
        // swallow the IO error rather than take the caller down.
        var file = Path.Combine(Path.GetTempPath(), "mn-log-blocker-" + Guid.NewGuid().ToString("N"));
        File.WriteAllText(file, "not a directory");
        try
        {
            DiagnosticLog.UseFolder(Path.Combine(file, "logs"));
            DiagnosticLog.Write("must not throw");
        }
        finally
        {
            DiagnosticLog.UseFolder(_dir);
            File.Delete(file);
        }
    }

    [Fact]
    public void ConcurrentWritersDoNotLoseOrTearLines()
    {
        DiagnosticLog.Enabled = true;
        Parallel.For(0, 200, i => DiagnosticLog.Write($"line {i}"));

        var lines = File.ReadAllLines(DiagnosticLog.LogPath);
        Assert.Equal(200, lines.Length);
        Assert.Equal(200, lines.Distinct().Count(l => l.Contains("line ")));
    }
}