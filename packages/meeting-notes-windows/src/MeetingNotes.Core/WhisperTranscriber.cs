using System.Diagnostics;

namespace MeetingNotes.Core;

/// <summary>
/// Runs the bundled whisper.cpp CLI (`whisper-cli.exe`) on a 16 kHz mono WAV and
/// parses its `-oj` JSON into tagged segments. The capture step already produces
/// 16 kHz mono tracks, so no resampling is needed here. Process invocation is
/// cross-platform; only the bundled binary is Windows-specific.
/// </summary>
public sealed class WhisperTranscriber(string whisperExePath)
{
    /// <summary>
    /// Transcribe one WAV, tagging every segment with <paramref name="speaker"/>.
    /// A silent track yields zero segments rather than an error.
    /// </summary>
    public async Task<List<TranscriptSegment>> TranscribeAsync(
        string wavPath, string modelPath, string speaker,
        string language = "auto", CancellationToken ct = default)
    {
        if (!File.Exists(modelPath))
            throw new InvalidOperationException($"whisper model not found: {modelPath}");

        var outBase = Path.Combine(
            Path.GetDirectoryName(wavPath)!, Path.GetFileNameWithoutExtension(wavPath));
        var jsonPath = outBase + ".json";

        var args = new[]
        {
            "-m", modelPath, "-f", wavPath, "-l", language,
            "-oj", "-of", outBase, "--suppress-nst",
            // Disable context conditioning to prevent repetition loops on long
            // recordings (port of macOS 0.37.1 fix).
            "-mc", "0",
        };
        await RunAsync(whisperExePath, args, ct);

        if (!File.Exists(jsonPath))
        {
            // whisper-cli exited 0 but produced no JSON: treat the track as silent
            // (no speech) and return no segments, matching the macOS app. A genuine
            // failure is already surfaced by RunAsync throwing on a non-zero exit,
            // so one silent track never fails the whole note.
            return [];
        }
        return Transcriber.ParseSegments(await File.ReadAllTextAsync(jsonPath, ct), speaker);
    }

    /// <summary>Returns the process exit code.</summary>
    private static async Task<int> RunAsync(string exe, IReadOnlyList<string> args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var proc = new Process { StartInfo = psi };
        proc.Start();

        // Read stdout and stderr concurrently to prevent pipe-buffer deadlocks.
        // whisper-cli writes progress/logs to both streams; if either fills the
        // OS pipe buffer (~4 KB) while nobody is reading, the process blocks on
        // write and WaitForExitAsync hangs forever.
        var stdoutTask = proc.StandardOutput.ReadToEndAsync(ct);
        var stderrTask = proc.StandardError.ReadToEndAsync(ct);
        await Task.WhenAll(stdoutTask, stderrTask);

        await proc.WaitForExitAsync(ct);
        if (proc.ExitCode != 0)
        {
            var stderr = await stderrTask;
            var tail = stderr.Length > 400 ? stderr[^400..] : stderr;
            throw new InvalidOperationException($"whisper-cli exited {proc.ExitCode}: {tail}");
        }
        return proc.ExitCode;
    }
}