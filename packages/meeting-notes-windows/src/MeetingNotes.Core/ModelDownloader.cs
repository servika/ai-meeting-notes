namespace MeetingNotes.Core;

/// <summary>
/// Downloads a whisper.cpp ggml model into the app's models directory, with
/// progress, for users who don't have a local model yet. C# port of the macOS
/// ModelDownloader. Also resolves the bundled <c>whisper-cli</c> executable.
/// </summary>
public sealed class ModelDownloader(HttpClient http)
{
    public static readonly IReadOnlyList<string> Available = new[]
    {
        "tiny", "tiny.en", "base", "base.en", "small", "small.en",
        "medium", "medium.en", "large-v3", "large-v3-turbo",
    };

    /// <summary>Directory where downloaded models live (<c>%APPDATA%/MeetingNotes/models</c>).</summary>
    public static string ModelsDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "MeetingNotes", "models");

    public static string FileName(string model) => $"ggml-{model}.bin";

    public static string ModelPath(string model) => Path.Combine(ModelsDir, FileName(model));

    public static string ModelUrl(string model) =>
        $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{FileName(model)}";

    /// <summary>True if <paramref name="model"/> is already downloaded.</summary>
    public static bool IsInstalled(string model) =>
        File.Exists(ModelPath(model)) && new FileInfo(ModelPath(model)).Length > 0;

    /// <summary>
    /// Resolve the whisper-cli executable: a copy bundled next to the app (or in a
    /// <c>vendor/</c> subfolder), else fall back to the name on PATH.
    /// </summary>
    public static string ResolveWhisperCli()
    {
        var exe = OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli";
        foreach (var candidate in new[]
                 {
                     Path.Combine(AppContext.BaseDirectory, exe),
                     Path.Combine(AppContext.BaseDirectory, "vendor", exe),
                 })
            if (File.Exists(candidate)) return candidate;
        return exe; // fall back to PATH
    }

    /// <summary>Download a model to <see cref="ModelsDir"/>, reporting 0…1 progress. Returns the path.</summary>
    public async Task<string> DownloadAsync(
        string model, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(ModelsDir);
        var dest = ModelPath(model);
        var tmp = dest + ".part";

        using var resp = await http.GetAsync(ModelUrl(model), HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();
        var total = resp.Content.Headers.ContentLength ?? -1;

        await using (var src = await resp.Content.ReadAsStreamAsync(ct))
        await using (var dst = File.Create(tmp))
        {
            var buffer = new byte[81920];
            long read = 0;
            int n;
            while ((n = await src.ReadAsync(buffer, ct)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, n), ct);
                read += n;
                if (total > 0) progress?.Report((double)read / total);
            }
        }

        if (File.Exists(dest)) File.Delete(dest);
        File.Move(tmp, dest);
        progress?.Report(1);
        return dest;
    }
}