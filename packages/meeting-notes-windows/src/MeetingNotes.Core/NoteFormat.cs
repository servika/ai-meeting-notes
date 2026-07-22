namespace MeetingNotes.Core;

/// <summary>
/// Builds and parses the Obsidian Markdown note for a meeting. The format is kept
/// byte-for-byte compatible with the macOS app (packages/meeting-engine
/// RecordingController.buildNote / frontmatterValue) so notes are interchangeable
/// across platforms.
/// </summary>
public static class NoteFormat
{
    /// <summary>
    /// Build the full note Markdown. <paramref name="audioBase"/> is the
    /// vault-relative recording path stem, e.g. "recordings/Meeting 2026-06-24".
    /// </summary>
    public static string BuildNote(
        string title,
        string date,
        string audioBase,
        int durationSeconds,
        int speakerCount,
        string summary,
        string transcript,
        string appVersion,
        string audioExt = "wav",
        string model = "")
    {
        var audioName = LastPathComponent(audioBase);

        var s = "---\ntype: meeting\ntags: [meeting]\ndate: " + date + "\naudio: " + audioBase + "\n";
        if (durationSeconds > 0) s += "duration: " + durationSeconds + "\n";
        if (speakerCount >= 2) s += "speakers: " + speakerCount + "\n";
        if (!string.IsNullOrEmpty(model)) s += "model: " + model + "\n";
        s += "app_version: " + appVersion + "\n";
        s += "---\n\n# " + title + "\n\n";
        if (!string.IsNullOrEmpty(summary)) s += summary + "\n\n";
        s += "## Transcript\n\n" + (string.IsNullOrEmpty(transcript) ? "_(no speech detected)_" : transcript) + "\n";
        s += "\n## Audio\n\n";
        if (audioExt is not null)
        {
            s += "**You (microphone)**\n\n![[" + audioName + ".mic." + audioExt + "]]\n\n";
            s += "**Them (system audio)**\n\n![[" + audioName + ".system." + audioExt + "]]\n";
        }
        else
        {
            s += "_Audio removed after transcription to save space._\n";
        }
        return s;
    }

    /// <summary>
    /// Replace the first top-level heading ("# ...") with "# " + <paramref name="title"/>,
    /// leaving the rest of the note (and its line endings) untouched. Returns the
    /// input unchanged when there is no such heading.
    /// </summary>
    public static string ReplaceFirstHeading(string content, string title)
    {
        var lines = content.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var bare = lines[i].TrimEnd('\r');
            if (bare.StartsWith("# ", StringComparison.Ordinal))
            {
                var cr = lines[i].Length > bare.Length ? "\r" : "";
                lines[i] = "# " + title + cr;
                return string.Join('\n', lines);
            }
        }
        return content;
    }

    /// <summary>
    /// Rewrite a note's "## Audio" section after an audio-retention pass:
    /// <paramref name="audioExt"/> is the new embed extension ("m4a"/"wav"), or
    /// null when the audio was deleted (emits the "removed" placeholder). Returns
    /// the content unchanged if the note has no Audio section.
    /// </summary>
    public static string RewriteAudioSection(string content, string audioName, string? audioExt)
    {
        const string marker = "\n## Audio\n";
        var idx = content.IndexOf(marker, StringComparison.Ordinal);
        if (idx < 0) return content;
        var head = content[..(idx + marker.Length)];
        var body = "\n";
        if (audioExt is not null)
        {
            body += "**You (microphone)**\n\n![[" + audioName + ".mic." + audioExt + "]]\n\n";
            body += "**Them (system audio)**\n\n![[" + audioName + ".system." + audioExt + "]]\n";
        }
        else
        {
            body += "_Audio removed after transcription to save space._\n";
        }
        return head + body;
    }

    /// <summary>
    /// Read a <c>key: value</c> line from a note's YAML frontmatter block, or null
    /// if the content has no frontmatter or the key is absent.
    /// </summary>
    public static string? FrontmatterValue(string key, string content)
    {
        if (!content.StartsWith("---", StringComparison.Ordinal)) return null;
        var prefix = key + ":";
        var inBlock = false;
        var lines = content.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i].TrimEnd('\r');
            if (i == 0 && line == "---") { inBlock = true; continue; }
            if (inBlock && line == "---") break;
            if (inBlock && line.StartsWith(prefix, StringComparison.Ordinal))
                return line.Substring(prefix.Length).Trim();
        }
        return null;
    }

    /// <summary>Extract the summary Markdown (sections between title and Transcript).</summary>
    public static string ExtractSummary(string content)
    {
        var body = StripFrontmatter(content);
        var idx = body.IndexOf("\n## Transcript", StringComparison.Ordinal);
        if (idx >= 0) body = body[..idx];
        // Skip the "# Title" heading
        var headingEnd = body.IndexOf('\n');
        if (headingEnd >= 0) body = body[(headingEnd + 1)..];
        return body.Trim();
    }

    /// <summary>Extract just the Transcript section body.</summary>
    public static string ExtractTranscript(string content)
    {
        var body = StripFrontmatter(content);
        var start = body.IndexOf("## Transcript", StringComparison.Ordinal);
        if (start < 0) return "";
        var after = body[(start + "## Transcript".Length)..];
        var audioIdx = after.IndexOf("\n## Audio", StringComparison.Ordinal);
        if (audioIdx >= 0) after = after[..audioIdx];
        return after.Trim();
    }

    /// <summary>Strip YAML frontmatter (--- ... ---) from content.</summary>
    public static string StripFrontmatter(string content)
    {
        if (!content.StartsWith("---", StringComparison.Ordinal)) return content;
        var end = content.IndexOf("\n---", 3, StringComparison.Ordinal);
        if (end < 0) return content;
        return content[(end + 4)..];
    }

    /// <summary>Last path component of a "/"-separated stem (no OS path rules).</summary>
    private static string LastPathComponent(string path)
    {
        var idx = path.LastIndexOf('/');
        return idx < 0 ? path : path[(idx + 1)..];
    }
}
