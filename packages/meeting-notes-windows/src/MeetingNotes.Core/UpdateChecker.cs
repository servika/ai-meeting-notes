using System.Net.Http.Headers;
using System.Text.Json;

namespace MeetingNotes.Core;

/// <summary>
/// Checks GitHub Releases for a newer Windows build. Privacy-safe: one
/// outbound request to the public GitHub API, throttled to once a day.
/// Port of macOS UpdateChecker.swift.
/// </summary>
public sealed class UpdateChecker
{
    private static readonly string LastCheckFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "MeetingNotes", "last-update-check");

    public string? LatestVersion { get; private set; }
    public string? ReleaseUrl { get; private set; }
    public bool UpdateAvailable => LatestVersion is not null && IsNewer(LatestVersion, BuildInfo.Version);

    public async Task CheckIfDueAsync(HttpClient http)
    {
        if (File.Exists(LastCheckFile))
        {
            var last = File.GetLastWriteTimeUtc(LastCheckFile);
            if ((DateTime.UtcNow - last).TotalHours < 24) return;
        }
        await CheckAsync(http);
    }

    public async Task CheckAsync(HttpClient http)
    {
        try
        {
            // Bound the request: the shared HttpClient has an infinite timeout for
            // long summaries/downloads, so a hung GitHub connection must not stall
            // the update check forever.
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://api.github.com/repos/servika/ai-meeting-notes/releases?per_page=20");
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            req.Headers.UserAgent.Add(new ProductInfoHeaderValue("MeetingNotes", BuildInfo.Version));

            using var resp = await http.SendAsync(req, cts.Token);
            if (!resp.IsSuccessStatusCode) return;
            var json = await resp.Content.ReadAsStringAsync(cts.Token);
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return;

            foreach (var rel in doc.RootElement.EnumerateArray())
            {
                if (rel.TryGetProperty("draft", out var d) && d.GetBoolean()) continue;
                if (rel.TryGetProperty("prerelease", out var p) && p.GetBoolean()) continue;
                if (!rel.TryGetProperty("tag_name", out var tag)) continue;
                var tagStr = tag.GetString() ?? "";
                if (!tagStr.StartsWith("win-v", StringComparison.Ordinal)) continue;

                LatestVersion = tagStr[5..]; // strip "win-v"
                ReleaseUrl = rel.TryGetProperty("html_url", out var url)
                    ? url.GetString()
                    : "https://github.com/servika/ai-meeting-notes/releases/latest";
                break;
            }
        }
        catch
        {
            // Best effort - don't crash on network errors.
        }
        finally
        {
            // Always record the check time, even on failure, so a rate-limited or
            // offline launch doesn't re-hit GitHub on every startup.
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LastCheckFile)!);
                File.WriteAllText(LastCheckFile, DateTime.UtcNow.ToString("O"));
            }
            catch { /* best effort */ }
        }
    }

    public static bool IsNewer(string a, string b)
    {
        static int[] Parts(string s)
        {
            var numeric = new string(s.TakeWhile(c => char.IsDigit(c) || c == '.').ToArray());
            return numeric.Split('.').Select(p => int.TryParse(p, out var v) ? v : 0).ToArray();
        }

        var pa = Parts(a);
        var pb = Parts(b);
        for (var i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            var x = i < pa.Length ? pa[i] : 0;
            var y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
