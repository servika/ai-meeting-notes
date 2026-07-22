using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

public class TranscriberTests
{
    [Fact]
    public void ParseSegments_reads_text_and_offsets()
    {
        const string json = """
        {"transcription":[
          {"text":" Hello there","offsets":{"from":1000,"to":2500}},
          {"text":"  ","offsets":{"from":2500,"to":3000}},
          {"text":"second","offsets":{"from":3000,"to":4000}}
        ]}
        """;
        var segs = Transcriber.ParseSegments(json, "You");
        Assert.Equal(2, segs.Count); // blank-text segment dropped
        Assert.Equal("Hello there", segs[0].Text);
        Assert.Equal(1.0, segs[0].Start);
        Assert.Equal(2.5, segs[0].End);
        Assert.Equal("You", segs[0].Speaker);
    }

    [Fact]
    public void ParseSegments_handles_missing_transcription_as_empty()
    {
        Assert.Empty(Transcriber.ParseSegments("{}", "Them"));
    }

    [Fact]
    public void DiarizedMarkdown_labels_turns_and_sorts_by_time()
    {
        var segs = new[]
        {
            new TranscriptSegment(0.0, 1.0, "Hi", "You"),
            new TranscriptSegment(2.0, 3.0, "Hello back", "Them"),
            new TranscriptSegment(1.0, 1.5, "there", "You"),
        };
        var md = Transcriber.DiarizedMarkdown(segs);
        var expected =
            "[0:00] **You:** Hi there\n\n" +
            "[0:02] **Them:** Hello back";
        Assert.Equal(expected, md);
    }

    [Fact]
    public void DiarizedMarkdown_breaks_paragraph_on_long_pause()
    {
        var segs = new[]
        {
            new TranscriptSegment(0.0, 1.0, "First part", "You"),
            new TranscriptSegment(5.0, 6.0, "after a gap", "You"), // gap > 1.5s
        };
        var md = Transcriber.DiarizedMarkdown(segs);
        // Same speaker, but the pause splits into two lines; only the first is labeled.
        Assert.Equal("[0:00] **You:** First part\n\n[0:05] after a gap", md);
    }

    [Theory]
    [InlineData(0, "0:00")]
    [InlineData(65, "1:05")]
    [InlineData(3661, "1:01:01")]
    public void Timestamp_formats(double seconds, string expected)
    {
        Assert.Equal(expected, Transcriber.Timestamp(seconds));
    }

    [Fact]
    public void NormalizedTokens_splits_and_lowercases()
    {
        var tokens = Transcriber.NormalizedTokens("Hello, World! Ок 123");
        Assert.Equal(new[] { "hello", "world", "ок", "123" }, tokens);
    }

    [Fact]
    public void RemoveCrossTrackEchoes_drops_duplicate_across_speakers()
    {
        // Simulate in-person meeting: same words appear on both tracks at the same time.
        var segs = new List<TranscriptSegment>
        {
            new(0.0, 3.0, "Let us discuss the quarterly budget review today", "You"),
            new(0.5, 3.5, "Let us discuss the quarterly budget review today", "Them"),
            new(5.0, 7.0, "Sounds good to me", "Them"),
        };
        var result = Transcriber.RemoveCrossTrackEchoes(segs);
        // The duplicate should be dropped; the unique segment kept.
        Assert.Equal(2, result.Count);
        Assert.Contains(result, s => s.Text.Contains("budget") && s.Speaker == "You");
        Assert.Contains(result, s => s.Text.Contains("Sounds good"));
    }

    [Fact]
    public void RemoveCrossTrackEchoes_keeps_different_content_across_speakers()
    {
        // Genuine remote meeting: different content on each track.
        var segs = new List<TranscriptSegment>
        {
            new(0.0, 3.0, "How is the project going on your end", "You"),
            new(4.0, 7.0, "We finished the backend last week and started testing", "Them"),
        };
        var result = Transcriber.RemoveCrossTrackEchoes(segs);
        Assert.Equal(2, result.Count);
    }

    [Fact]
    public void RemoveCrossTrackEchoes_skips_short_segments()
    {
        // Short segments (< 4 tokens) are never dropped even if duplicated.
        var segs = new List<TranscriptSegment>
        {
            new(0.0, 1.0, "yes okay", "You"),
            new(0.5, 1.5, "yes okay", "Them"),
        };
        var result = Transcriber.RemoveCrossTrackEchoes(segs);
        Assert.Equal(2, result.Count);
    }

    [Fact]
    public void RemoveCrossTrackEchoes_single_speaker_noop()
    {
        var segs = new List<TranscriptSegment>
        {
            new(0.0, 1.0, "Hello world this is a test sentence", "You"),
            new(2.0, 3.0, "Another test sentence here for testing", "You"),
        };
        var result = Transcriber.RemoveCrossTrackEchoes(segs);
        Assert.Equal(2, result.Count);
    }
}