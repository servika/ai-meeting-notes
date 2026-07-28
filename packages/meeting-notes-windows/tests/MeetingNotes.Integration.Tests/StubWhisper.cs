using System.Runtime.InteropServices;

namespace MeetingNotes.Integration.Tests;

/// <summary>
/// A stand-in for <c>whisper-cli</c>: a real executable script that the pipeline
/// launches exactly as it launches the bundled binary (same arguments, same
/// process plumbing, same JSON hand-off on disk). Only the model inference is
/// faked - everything around it is the production code path.
/// </summary>
public sealed class StubWhisper
{
    private static bool IsWindows => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

    /// <summary>Path to pass as the whisper executable.</summary>
    public string ExePath { get; }

    private StubWhisper(string exePath) => ExePath = exePath;

    /// <summary>A stub that transcribes both tracks the same way.</summary>
    public static StubWhisper Emitting(string dir, params (double Start, double End, string Text)[] segments) =>
        Emitting(dir, segments, segments);

    /// <summary>
    /// A stub that transcribes each track differently - it picks its output from
    /// the <c>-f</c> path, as the real CLI would from the audio itself.
    /// </summary>
    public static StubWhisper Emitting(string dir,
        (double Start, double End, string Text)[] system,
        (double Start, double End, string Text)[] mic)
    {
        var id = Guid.NewGuid().ToString("N");
        var systemJson = Path.Combine(dir, $"stub-system-{id}.json");
        var micJson = Path.Combine(dir, $"stub-mic-{id}.json");
        File.WriteAllText(systemJson, BuildJson(system));
        File.WriteAllText(micJson, BuildJson(mic));
        return Create(dir, copyFrom: systemJson, exitCode: 0, micCopyFrom: micJson);
    }

    /// <summary>A stub that exits 0 without producing JSON (a silent track).</summary>
    public static StubWhisper Silent(string dir) => Create(dir, copyFrom: null, exitCode: 0);

    /// <summary>A stub that fails the way a broken/incompatible binary would.</summary>
    public static StubWhisper Failing(string dir, string message = "whisper: model load failed") =>
        Create(dir, copyFrom: null, exitCode: 1, stderr: message);

    /// <summary>
    /// The JSON whisper writes with <c>-oj</c>: segments with millisecond offsets.
    /// </summary>
    public static string BuildJson(params (double Start, double End, string Text)[] segments)
    {
        var items = segments.Select(s => $$"""
                {
                  "timestamps": { "from": "00:00:00,000", "to": "00:00:00,000" },
                  "offsets": { "from": {{(int)(s.Start * 1000)}}, "to": {{(int)(s.End * 1000)}} },
                  "text": {{System.Text.Json.JsonSerializer.Serialize(s.Text)}}
                }
            """);
        return $$"""
            {
              "systeminfo": "stub",
              "model": { "type": "stub" },
              "params": { "model": "stub" },
              "result": { "language": "en" },
              "transcription": [
            {{string.Join(",\n", items)}}
              ]
            }
            """;
    }

    private static StubWhisper Create(
        string dir, string? copyFrom, int exitCode, string stderr = "", string? micCopyFrom = null)
    {
        var name = "stub-whisper-" + Guid.NewGuid().ToString("N");
        var path = Path.Combine(dir, name + (IsWindows ? ".cmd" : ".sh"));
        // Which JSON to emit is chosen from the -f track path, so a run that fed the
        // wrong file (or lost the -of base) fails the test instead of passing quietly.
        var source = micCopyFrom ?? copyFrom;

        File.WriteAllText(path, IsWindows
            ? $"""
               @echo off
               setlocal enabledelayedexpansion
               set OF=
               set F=
               :loop
               if "%~1"=="" goto done
               if "%~1"=="-of" set OF=%~2
               if "%~1"=="-f" set F=%~2
               shift
               goto loop
               :done
               {(stderr.Length > 0 ? $"echo {stderr} 1>&2" : "")}
               set SRC={copyFrom}
               echo !F! | find ".mic." >nul && set SRC={source}
               {(copyFrom is null ? "" : "if not \"%SRC%\"==\"\" copy /y \"!SRC!\" \"!OF!.json\" >nul")}
               exit /b {exitCode}
               """
            : $"""
               #!/bin/sh
               OF=""
               F=""
               while [ $# -gt 0 ]; do
                 if [ "$1" = "-of" ]; then OF="$2"; fi
                 if [ "$1" = "-f" ]; then F="$2"; fi
                 shift
               done
               {(stderr.Length > 0 ? $"echo '{stderr}' >&2" : "")}
               SRC="{copyFrom}"
               case "$F" in *.mic.*) SRC="{source}";; esac
               {(copyFrom is null ? "" : "cp \"$SRC\" \"$OF.json\"")}
               exit {exitCode}
               """);

        if (!IsWindows) File.SetUnixFileMode(path,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return new StubWhisper(path);
    }
}
