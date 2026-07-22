using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

public class SummarizerTests
{
    [Fact]
    public void Fill_replaces_placeholder()
    {
        Assert.Equal("a TX b", Summarizer.Fill("a {{transcript}} b", "TX"));
    }

    [Fact]
    public void Fill_appends_when_no_placeholder()
    {
        Assert.Equal("prompt\n\nTX", Summarizer.Fill("prompt", "TX"));
    }

    [Fact]
    public void ChunkText_keeps_short_text_as_one_chunk()
    {
        var chunks = Summarizer.ChunkText("a\n\nb\n\nc", maxChars: 1000);
        Assert.Single(chunks);
        Assert.Equal("a\n\nb\n\nc", chunks[0]);
    }

    [Fact]
    public void ChunkText_breaks_on_blank_lines_within_limit()
    {
        // Two 10-char paragraphs; limit forces a split between them rather than mid-paragraph.
        var p = new string('x', 10);
        var chunks = Summarizer.ChunkText($"{p}\n\n{p}", maxChars: 12);
        Assert.Equal(2, chunks.Count);
        Assert.All(chunks, c => Assert.Equal(p, c));
    }

    [Fact]
    public void ChunkText_hard_splits_a_single_oversized_paragraph()
    {
        var chunks = Summarizer.ChunkText(new string('y', 25), maxChars: 10);
        Assert.Equal(new[] { 10, 10, 5 }, chunks.Select(c => c.Length).ToArray());
        Assert.Equal(new string('y', 25), string.Concat(chunks));
    }

    [Fact]
    public void ChunkText_every_chunk_within_limit()
    {
        var text = string.Join("\n\n", Enumerable.Repeat(new string('z', 30), 50));
        var chunks = Summarizer.ChunkText(text, maxChars: 100);
        Assert.All(chunks, c => Assert.True(c.Length <= 100, $"chunk len {c.Length} > 100"));
    }
}