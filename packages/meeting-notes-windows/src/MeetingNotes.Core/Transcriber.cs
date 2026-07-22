using System.Globalization;
using System.Text;
using System.Text.Json;

namespace MeetingNotes.Core;

/// <summary>One transcribed span of speech, tagged with who spoke ("You"/"Them").</summary>
public readonly record struct TranscriptSegment(double Start, double End, string Text, string Speaker);

/// <summary>
/// Transcription + "You vs. Them" diarization. C# port of the macOS Transcriber
/// (packages/meeting-engine Transcriber.swift). The whisper.cpp invocation and
/// 16 kHz resampling are Windows-only (added in a later phase); the JSON parsing
/// and the timestamp-merge into a speaker-labeled transcript are pure and tested
/// here, kept identical to the macOS output so notes match across platforms.
/// </summary>
public static class Transcriber
{
    /// <summary>
    /// Parse whisper-cli `-oj` JSON output into segments tagged with
    /// <paramref name="speaker"/>. A silent track produces no/empty transcription
    /// - that's zero segments, not an error.
    /// </summary>
    public static List<TranscriptSegment> ParseSegments(string json, string speaker)
    {
        var segments = new List<TranscriptSegment>();
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("transcription", out var rawSegs) ||
            rawSegs.ValueKind != JsonValueKind.Array)
            return segments;

        foreach (var seg in rawSegs.EnumerateArray())
        {
            var text = (seg.TryGetProperty("text", out var t) ? t.GetString() ?? "" : "").Trim();
            if (text.Length == 0) continue;
            double from = 0, to = 0;
            if (seg.TryGetProperty("offsets", out var offsets))
            {
                from = NumberMs(offsets, "from");
                to = NumberMs(offsets, "to");
            }
            segments.Add(new TranscriptSegment(from / 1000, to / 1000, text, speaker));
        }
        return segments;
    }

    /// <summary>
    /// Merge segments from all speakers into a chronological, labeled transcript.
    /// Consecutive segments from the same speaker collapse into one line; long
    /// monologues break into paragraphs on a pause or a long, sentence-ending run.
    /// </summary>
    public static string DiarizedMarkdown(IEnumerable<TranscriptSegment> segments)
    {
        var sorted = segments.OrderBy(s => s.Start).ToList();
        var blocks = new List<string>();
        var speaker = "";
        var paragraph = new StringBuilder();
        var firstOfTurn = true;
        var lastEnd = 0.0;
        var paragraphStart = 0.0;

        void EndParagraph()
        {
            var trimmed = paragraph.ToString().Trim();
            if (trimmed.Length > 0)
            {
                var label = firstOfTurn ? $"**{speaker}:** " : "";
                blocks.Add($"[{Timestamp(paragraphStart)}] {label}{trimmed}");
                firstOfTurn = false;
            }
            paragraph.Clear();
        }

        foreach (var seg in sorted)
        {
            var text = seg.Text.Trim();
            if (text.Length == 0) continue;
            if (seg.Speaker != speaker)
            {
                EndParagraph();
                speaker = seg.Speaker;
                firstOfTurn = true;
            }
            else if (paragraph.Length > 0)
            {
                var gap = seg.Start - lastEnd;
                var p = paragraph.ToString();
                var endsSentence = p.EndsWith('.') || p.EndsWith('!') || p.EndsWith('?') || p.EndsWith('…');
                if (gap > 1.5 || (p.Length > 320 && endsSentence))
                    EndParagraph();
            }
            if (paragraph.Length == 0) paragraphStart = seg.Start;
            paragraph.Append(paragraph.Length == 0 ? "" : " ").Append(text);
            lastEnd = seg.End;
        }
        EndParagraph();
        return string.Join("\n\n", blocks);
    }

    /// <summary>
    /// Remove cross-track echo before merging. Port of macOS 0.29.0 fix.
    /// In an in-person or speakerphone meeting the mic ("You") and system
    /// ("Them") tracks capture the same room, so every utterance is transcribed
    /// on *both* tracks. This drops a segment only when its words are largely
    /// already covered by kept segments from the other speaker at the same time.
    /// Segments are processed richest-first so the most complete copy survives.
    /// Genuine remote meetings are unaffected (different audio per track means
    /// no word + time overlap).
    /// </summary>
    public static List<TranscriptSegment> RemoveCrossTrackEchoes(List<TranscriptSegment> segments)
    {
        if (segments.Count == 0) return segments;
        var speakers = new HashSet<string>(segments.Select(s => s.Speaker));
        if (speakers.Count < 2) return segments;

        const double window = 6.0;
        const double containmentThreshold = 0.75;
        const int minTokens = 4;

        var tokens = segments.Select(s => NormalizedTokens(s.Text)).ToArray();

        // Position by start time so each segment only scans nearby ones.
        var byStart = Enumerable.Range(0, segments.Count)
            .OrderBy(i => segments[i].Start).ToArray();
        var pos = new int[segments.Count];
        for (var p = 0; p < byStart.Length; p++) pos[byStart[p]] = p;

        // Decide keep/drop richest-first (more tokens, then earlier, then speaker).
        var byRichness = Enumerable.Range(0, segments.Count)
            .OrderByDescending(i => tokens[i].Length)
            .ThenBy(i => segments[i].Start)
            .ThenBy(i => segments[i].Speaker, StringComparer.Ordinal)
            .ToArray();

        var kept = new HashSet<int>();
        var dropped = new HashSet<int>();

        foreach (var i in byRichness)
        {
            if (tokens[i].Length < minTokens) { kept.Add(i); continue; }
            var si = segments[i];

            // Pool tokens from already-KEPT opposite-speaker segments overlapping i.
            var pool = new Dictionary<string, int>();
            foreach (var dir in new[] { -1, 1 })
            {
                var p = pos[i] + dir;
                while (p >= 0 && p < byStart.Length)
                {
                    var j = byStart[p];
                    var sj = segments[j];
                    if (dir == 1 && sj.Start > si.End + window) break;
                    if (dir == -1 && sj.End < si.Start - window) break;
                    p += dir;
                    if (sj.Speaker == si.Speaker || !kept.Contains(j)) continue;
                    if (!(sj.Start <= si.End + window && sj.End >= si.Start - window)) continue;
                    foreach (var t in tokens[j])
                    {
                        pool.TryGetValue(t, out var cnt);
                        pool[t] = cnt + 1;
                    }
                }
            }

            // Multiset containment of i's words within the kept other-track tokens.
            var matched = 0;
            foreach (var t in tokens[i])
            {
                if (pool.TryGetValue(t, out var cnt) && cnt > 0)
                {
                    pool[t] = cnt - 1;
                    matched++;
                }
            }
            if ((double)matched / tokens[i].Length >= containmentThreshold)
                dropped.Add(i);
            else
                kept.Add(i);
        }

        return segments.Where((_, idx) => !dropped.Contains(idx)).ToList();
    }

    /// <summary>Lowercased alphanumeric word tokens (Unicode-aware).</summary>
    internal static string[] NormalizedTokens(string text)
    {
        var words = new List<string>();
        var sb = new StringBuilder();
        foreach (var c in text.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c))
                sb.Append(c);
            else if (sb.Length > 0)
            {
                words.Add(sb.ToString());
                sb.Clear();
            }
        }
        if (sb.Length > 0) words.Add(sb.ToString());
        return words.ToArray();
    }

    /// <summary>Format seconds-from-start as <c>m:ss</c>, or <c>h:mm:ss</c> past an hour.</summary>
    internal static string Timestamp(double seconds)
    {
        var s = Math.Max(0, (int)Math.Round(seconds));
        int h = s / 3600, m = (s % 3600) / 60, sec = s % 60;
        return h > 0
            ? $"{h}:{m:D2}:{sec:D2}"
            : $"{m}:{sec:D2}";
    }

    private static double NumberMs(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var v)) return 0;
        return v.ValueKind switch
        {
            JsonValueKind.Number => v.GetDouble(),
            JsonValueKind.String when double.TryParse(v.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var d) => d,
            _ => 0,
        };
    }
}