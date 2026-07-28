using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// The note-editing half of <see cref="NoteFormat"/>: rewriting the audio section
/// after a retention pass, renaming the heading, and reading sections back out.
/// </summary>
public class NoteFormatSectionTests
{
    private static string Note(string summary = "## Summary\nWe met.", string transcript = "[0:00] **You:** hi") =>
        NoteFormat.BuildNote("Meeting X", "2026-06-24 10-00-00", "recordings/Meeting X",
            600, 0, summary, transcript, "0.5.0");

    // ---- RewriteAudioSection ----

    [Fact]
    public void RewriteAudioSection_switches_the_embeds_to_the_new_extension()
    {
        var rewritten = NoteFormat.RewriteAudioSection(Note(), "Meeting X", "m4a");

        Assert.Contains("![[Meeting X.mic.m4a]]", rewritten);
        Assert.Contains("![[Meeting X.system.m4a]]", rewritten);
        Assert.DoesNotContain(".wav", rewritten);
    }

    [Fact]
    public void RewriteAudioSection_replaces_the_embeds_with_a_note_when_audio_was_deleted()
    {
        var rewritten = NoteFormat.RewriteAudioSection(Note(), "Meeting X", null);

        Assert.Contains("_Audio removed after transcription to save space._", rewritten);
        Assert.DoesNotContain("![[", rewritten);
    }

    [Fact]
    public void RewriteAudioSection_leaves_the_summary_and_transcript_intact()
    {
        var rewritten = NoteFormat.RewriteAudioSection(Note(), "Meeting X", "m4a");

        Assert.Contains("## Summary\nWe met.", rewritten);
        Assert.Contains("[0:00] **You:** hi", rewritten);
        Assert.Equal("recordings/Meeting X", NoteFormat.FrontmatterValue("audio", rewritten));
    }

    [Fact]
    public void RewriteAudioSection_is_idempotent()
    {
        var once = NoteFormat.RewriteAudioSection(Note(), "Meeting X", "m4a");
        Assert.Equal(once, NoteFormat.RewriteAudioSection(once, "Meeting X", "m4a"));
    }

    [Fact]
    public void RewriteAudioSection_returns_a_note_without_an_audio_section_unchanged()
    {
        const string content = "---\ntype: meeting\n---\n\n# T\n\n## Transcript\n\nx\n";
        Assert.Equal(content, NoteFormat.RewriteAudioSection(content, "T", "m4a"));
    }

    // ---- ReplaceFirstHeading ----

    [Fact]
    public void ReplaceFirstHeading_renames_only_the_first_heading()
    {
        Assert.Equal("# New\n\ntext\n\n# Two\n",
            NoteFormat.ReplaceFirstHeading("# One\n\ntext\n\n# Two\n", "New"));
    }

    [Fact]
    public void ReplaceFirstHeading_preserves_crlf_line_endings()
    {
        Assert.Equal("# New\r\nbody\r\n", NoteFormat.ReplaceFirstHeading("# Old\r\nbody\r\n", "New"));
    }

    [Fact]
    public void ReplaceFirstHeading_ignores_deeper_headings_and_content_without_one()
    {
        Assert.Equal("## Sub\ntext", NoteFormat.ReplaceFirstHeading("## Sub\ntext", "New"));
        Assert.Equal("no heading", NoteFormat.ReplaceFirstHeading("no heading", "New"));
    }

    [Fact]
    public void ReplaceFirstHeading_renames_the_title_of_a_real_note()
    {
        var renamed = NoteFormat.ReplaceFirstHeading(Note(), "Budget review");

        Assert.Contains("# Budget review", renamed);
        Assert.DoesNotContain("# Meeting X", renamed);
        // Frontmatter (including the audio link) is untouched by a rename.
        Assert.Equal("recordings/Meeting X", NoteFormat.FrontmatterValue("audio", renamed));
    }

    // ---- extraction ----

    [Fact]
    public void ExtractSummary_returns_the_sections_between_the_title_and_the_transcript()
    {
        Assert.Equal("## Summary\nWe met.", NoteFormat.ExtractSummary(Note()));
    }

    [Fact]
    public void ExtractSummary_is_empty_when_the_note_has_no_summary()
    {
        Assert.Equal("", NoteFormat.ExtractSummary(Note(summary: "")));
    }

    [Fact]
    public void ExtractTranscript_returns_only_the_transcript_body()
    {
        Assert.Equal("[0:00] **You:** hi", NoteFormat.ExtractTranscript(Note()));
    }

    [Fact]
    public void ExtractTranscript_is_empty_when_there_is_no_transcript_section()
    {
        Assert.Equal("", NoteFormat.ExtractTranscript("---\ntype: meeting\n---\n\n# T\n"));
    }

    [Fact]
    public void ExtractTranscript_keeps_a_multi_paragraph_transcript_whole()
    {
        const string transcript = "[0:00] **You:** one\n\n[0:10] **Them:** two";
        Assert.Equal(transcript, NoteFormat.ExtractTranscript(Note(transcript: transcript)));
    }

    [Fact]
    public void StripFrontmatter_removes_the_block_and_leaves_content_without_one_alone()
    {
        Assert.Contains("# Meeting X", NoteFormat.StripFrontmatter(Note()));
        Assert.DoesNotContain("type: meeting", NoteFormat.StripFrontmatter(Note()));
        Assert.Equal("# No frontmatter\n", NoteFormat.StripFrontmatter("# No frontmatter\n"));
    }
}
