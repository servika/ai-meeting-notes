using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

public class NoteFormatTests
{
    [Fact]
    public void BuildNote_matches_macos_format_exactly()
    {
        var note = NoteFormat.BuildNote(
            title: "Daily sync",
            date: "2026-06-24 09-30-00",
            audioBase: "recordings/Daily sync",
            durationSeconds: 1800,
            speakerCount: 3,
            summary: "## Summary\n\nWe shipped it.",
            transcript: "**You:** Hi\n\n**Them:** Hello",
            appVersion: "0.1.0");

        const string expected =
            "---\n" +
            "type: meeting\n" +
            "tags: [meeting]\n" +
            "date: 2026-06-24 09-30-00\n" +
            "audio: recordings/Daily sync\n" +
            "duration: 1800\n" +
            "speakers: 3\n" +
            "app_version: 0.1.0\n" +
            "---\n\n" +
            "# Daily sync\n\n" +
            "## Summary\n\nWe shipped it.\n\n" +
            "## Transcript\n\n**You:** Hi\n\n**Them:** Hello\n" +
            "\n## Audio\n\n**You (microphone)**\n\n![[Daily sync.mic.wav]]\n\n" +
            "**Them (system audio)**\n\n![[Daily sync.system.wav]]\n";

        Assert.Equal(expected, note);
    }

    [Fact]
    public void BuildNote_omits_duration_speakers_and_summary_when_absent()
    {
        var note = NoteFormat.BuildNote(
            title: "Quick chat", date: "2026-06-24 10-00-00",
            audioBase: "recordings/Quick chat",
            durationSeconds: 0, speakerCount: 1, summary: "", transcript: "",
            appVersion: "0.1.0");

        Assert.DoesNotContain("duration:", note);
        Assert.DoesNotContain("speakers:", note); // 1 < 2, so omitted
        Assert.DoesNotContain("summary_model:", note); // no summary == nothing to credit
        Assert.Contains("## Transcript\n\n_(no speech detected)_\n", note);
        // No blank summary block between the title and the Transcript heading.
        Assert.Contains("# Quick chat\n\n## Transcript", note);
    }

    /// <summary>
    /// summary_model must match what the macOS app writes, byte for byte, and must
    /// not collide with the whisper `model:` key.
    /// </summary>
    [Fact]
    public void BuildNote_writes_summary_model_after_model()
    {
        var note = NoteFormat.BuildNote(
            title: "Daily sync", date: "2026-06-24 09-30-00",
            audioBase: "recordings/Daily sync",
            durationSeconds: 60, speakerCount: 0,
            summary: "## Summary\n\nx", transcript: "y", appVersion: "0.1.0",
            audioExt: "wav", model: "ggml-large-v3-turbo.bin",
            summaryModel: "claude/claude-opus-4-8");

        Assert.Contains(
            "model: ggml-large-v3-turbo.bin\nsummary_model: claude/claude-opus-4-8\napp_version: 0.1.0\n",
            note);
        Assert.Equal("ggml-large-v3-turbo.bin", NoteFormat.FrontmatterValue("model", note));
        Assert.Equal("claude/claude-opus-4-8", NoteFormat.FrontmatterValue("summary_model", note));
    }

    [Fact]
    public void SummaryEngine_label_carries_provider_and_model_without_the_api_key()
    {
        Assert.Equal("ollama/llama3.1:8b",
            new SummaryEngine.Ollama("http://localhost:11434", "llama3.1:8b").Label);

        var claude = new SummaryEngine.Claude("sk-ant-secret", "claude-opus-4-8");
        Assert.Equal("claude/claude-opus-4-8", claude.Label);
        Assert.DoesNotContain("secret", claude.Label);
    }

    [Fact]
    public void FrontmatterValue_reads_back_what_BuildNote_wrote()
    {
        var note = NoteFormat.BuildNote(
            "Planning", "2026-06-24 14-00-00", "recordings/Planning",
            3600, 4, "summary", "transcript", "9.9.9");

        Assert.Equal("meeting", NoteFormat.FrontmatterValue("type", note));
        Assert.Equal("2026-06-24 14-00-00", NoteFormat.FrontmatterValue("date", note));
        Assert.Equal("recordings/Planning", NoteFormat.FrontmatterValue("audio", note));
        Assert.Equal("3600", NoteFormat.FrontmatterValue("duration", note));
        Assert.Equal("4", NoteFormat.FrontmatterValue("speakers", note));
        Assert.Equal("9.9.9", NoteFormat.FrontmatterValue("app_version", note));
    }

    [Fact]
    public void FrontmatterValue_returns_null_for_missing_key_or_no_frontmatter()
    {
        var note = NoteFormat.BuildNote("T", "d", "recordings/T", 0, 0, "", "", "v");
        Assert.Null(NoteFormat.FrontmatterValue("nonexistent", note));
        Assert.Null(NoteFormat.FrontmatterValue("type", "no frontmatter here"));
    }

    [Fact]
    public void FrontmatterValue_does_not_read_body_lines_after_the_block()
    {
        // A "type:"-looking line in the body must not be picked up.
        var content = "---\ndate: x\n---\n\ntype: should-be-ignored\n";
        Assert.Null(NoteFormat.FrontmatterValue("type", content));
    }
}