using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// The summary stage's guard rails and prompt catalog. Real engine calls need a
/// running Ollama or a Claude key, so only the paths that fail (or must not fire)
/// before any request are exercised here.
/// </summary>
public class SummaryEngineTests
{
    private static Summarizer NewSummarizer() => new(new HttpClient());

    [Fact]
    public void The_default_prompt_asks_for_the_four_sections_and_takes_a_transcript()
    {
        Assert.Contains("{{transcript}}", SummaryPrompts.Default);
        foreach (var heading in new[] { "## Short summary", "## Summary", "## Topics discussed", "## Action items" })
            Assert.Contains(heading, SummaryPrompts.Default);
    }

    [Fact]
    public async Task Ollama_without_a_model_fails_before_any_request()
    {
        var ex = await Assert.ThrowsAsync<SummaryException>(() => NewSummarizer().SummarizeAsync(
            "transcript", SummaryPrompts.Default, new SummaryEngine.Ollama("http://localhost:11434", "")));

        Assert.Contains("model", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Claude_without_an_api_key_fails_before_any_request()
    {
        var ex = await Assert.ThrowsAsync<SummaryException>(() => NewSummarizer().SummarizeAsync(
            "transcript", SummaryPrompts.Default, new SummaryEngine.Claude("", Summarizer.ClaudeDefaultModel)));

        Assert.Contains("key", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void MapPrompt_carries_the_chunk_and_its_position()
    {
        var prompt = Summarizer.MapPrompt("chunk text", 2, 5);

        Assert.Contains("chunk text", prompt);
        Assert.Contains("2", prompt);
        Assert.Contains("5", prompt);
    }

    [Fact]
    public void Engines_compare_by_value_so_settings_changes_are_detectable()
    {
        Assert.Equal(new SummaryEngine.Ollama("http://x", "m"), new SummaryEngine.Ollama("http://x", "m"));
        Assert.NotEqual<SummaryEngine>(new SummaryEngine.Ollama("http://x", "m"), new SummaryEngine.Claude("k", "m"));
    }
}

/// <summary>
/// Whisper invocation guards. Running the real CLI needs a model and a bundled
/// binary, so only the pre-flight checks are covered.
/// </summary>
public class WhisperTranscriberTests
{
    [Fact]
    public async Task A_missing_model_is_reported_before_the_process_starts()
    {
        var transcriber = new WhisperTranscriber("whisper-cli-that-does-not-exist");

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            transcriber.TranscribeAsync("audio.wav", "/no/such/model.bin", "You"));

        Assert.Contains("model not found", ex.Message);
    }
}