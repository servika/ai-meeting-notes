using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace MeetingNotes.Core;

/// <summary>Where a summary is generated - a local Ollama model or the Claude API.</summary>
public abstract record SummaryEngine
{
    public sealed record Ollama(string Url, string Model) : SummaryEngine;
    public sealed record Claude(string ApiKey, string Model) : SummaryEngine;

    /// <summary>
    /// "provider/model" - recorded in the note so a summary can be traced back to
    /// what produced it. Never contains the API key. Matches the macOS
    /// SummaryEngine.label so both apps write the same value.
    /// </summary>
    public string Label => this switch
    {
        Ollama o => "ollama/" + o.Model,
        Claude c => "claude/" + c.Model,
        _ => "",
    };
}

public sealed class SummaryException(string message) : Exception(message);

/// <summary>
/// Meeting summary + action items from a transcript. C# port of the macOS
/// Summarizer (packages/meeting-engine Summarizer.swift), including the
/// map-reduce path for long transcripts. The chunking and prompt-fill logic is
/// pure and unit-tested; the HTTP calls go through an injected HttpClient.
/// </summary>
public sealed class Summarizer(HttpClient http)
{
    /// <summary>Recommended default Claude model for new code (see the claude-api skill).</summary>
    public const string ClaudeDefaultModel = "claude-opus-4-8";

    // Transcripts longer than this (chars) are summarized via map-reduce instead
    // of one pass - sized near what fits a 32k-token context with headroom.
    internal const int MapReduceThresholdChars = 90_000;
    // Per-chunk size in the map phase (~18k tokens - comfortably fits 32k models).
    internal const int ChunkChars = 60_000;

    public async Task<string> SummarizeAsync(
        string transcript, string prompt, SummaryEngine engine,
        CancellationToken ct = default, IProgress<string>? progress = null)
    {
        // Short/medium meetings: one pass.
        if (transcript.Length <= MapReduceThresholdChars)
        {
            progress?.Report("Summarizing (single pass)…");
            return await RunAsync(Fill(prompt, transcript), engine, keepAlive: 0, ct);
        }

        // Long meetings: map-reduce. Summarize each chunk into partial notes (model
        // kept loaded between chunks), then combine those into the final summary.
        var chunks = ChunkText(transcript, ChunkChars);
        var partials = new List<string>();
        for (var i = 0; i < chunks.Count; i++)
        {
            progress?.Report($"Summarizing chunk {i + 1}/{chunks.Count}…");
            var mapped = await RunAsync(MapPrompt(chunks[i], i + 1, chunks.Count), engine, keepAlive: 300, ct);
            if (mapped.Length > 0) partials.Add($"## Part {i + 1} of {chunks.Count}\n{mapped}");
        }
        progress?.Report("Combining summaries…");
        var combined = string.Join("\n\n", partials);
        return await RunAsync(Fill(prompt, combined), engine, keepAlive: 0, ct);
    }

    /// <summary>Substitute text into a prompt's {{transcript}} placeholder (or append if absent).</summary>
    internal static string Fill(string prompt, string text) =>
        prompt.Contains("{{transcript}}", StringComparison.Ordinal)
            ? prompt.Replace("{{transcript}}", text)
            : $"{prompt}\n\n{text}";

    internal static string MapPrompt(string chunk, int part, int total) =>
        $"This is part {part} of {total} of a meeting transcript (lines labeled You/Them; " +
        "speech-recognition output). Extract the notable content from THIS part only, as concise " +
        "Markdown bullet points: key discussion points, decisions, concrete numbers/amounts/dates/limits, " +
        "named owners, and any action items (with owner and deadline if stated). No intro or conclusion. " +
        "Write in the same language as the transcript.\n\nTranscript part:\n" + chunk;

    /// <summary>Split text into &lt;= maxChars chunks, breaking on blank lines where possible.</summary>
    internal static List<string> ChunkText(string text, int maxChars)
    {
        var chunks = new List<string>();
        var current = new StringBuilder();
        foreach (var para in text.Split("\n\n"))
        {
            if (current.Length == 0)
                current.Append(para);
            else if (current.Length + para.Length + 2 <= maxChars)
                current.Append("\n\n").Append(para);
            else
            {
                chunks.Add(current.ToString());
                current.Clear().Append(para);
            }
            // A single oversized paragraph: hard-split it.
            while (current.Length > maxChars)
            {
                chunks.Add(current.ToString(0, maxChars));
                var rest = current.ToString(maxChars, current.Length - maxChars);
                current.Clear().Append(rest);
            }
        }
        if (current.Length > 0) chunks.Add(current.ToString());
        return chunks;
    }

    private Task<string> RunAsync(string prompt, SummaryEngine engine, int keepAlive, CancellationToken ct) =>
        engine switch
        {
            SummaryEngine.Ollama o => OllamaAsync(prompt, o.Url, o.Model, keepAlive, ct),
            SummaryEngine.Claude c => ClaudeAsync(prompt, c.ApiKey, c.Model, ct),
            _ => throw new SummaryException("unknown summary engine"),
        };

    private async Task<string> OllamaAsync(string prompt, string url, string model, int keepAlive, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(model)) throw new SummaryException("no Ollama model set");
        var endpoint = url.TrimEnd('/') + "/api/generate";
        // num_ctx: Ollama defaults to a tiny context and silently truncates long prompts to the
        // end, dropping the start of long transcripts. Size the window to fit the whole prompt.
        var estTokens = prompt.Length / 2 + 2048;
        var numCtx = Math.Min(32768, Math.Max(8192, estTokens));
        var body = new
        {
            model,
            prompt,
            stream = false,
            options = new { temperature = 0, num_ctx = numCtx },
            keep_alive = keepAlive,
        };

        JsonElement obj;
        try
        {
            obj = await PostAsync(endpoint, body, headers: null, ct);
        }
        catch (HttpRequestException)
        {
            throw new SummaryException(
                $"Can't reach Ollama at {url}. Install it from ollama.com and run a model " +
                $"(e.g. `ollama pull {(string.IsNullOrEmpty(model) ? "qwen2.5:7b" : model)}`), " +
                "or set the Summary engine to Claude or None in Settings.");
        }
        if (obj.TryGetProperty("error", out var err))
            throw new SummaryException($"Ollama: {err.GetString()}");
        return (obj.TryGetProperty("response", out var r) ? r.GetString() ?? "" : "").Trim();
    }

    private async Task<string> ClaudeAsync(string prompt, string apiKey, string model, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(apiKey)) throw new SummaryException("no Claude API key set");
        var body = new
        {
            model = string.IsNullOrEmpty(model) ? ClaudeDefaultModel : model,
            max_tokens = 2048,
            messages = new[] { new { role = "user", content = prompt } },
        };
        var headers = new (string, string)[]
        {
            ("x-api-key", apiKey),
            ("anthropic-version", "2023-06-01"),
        };
        var obj = await PostAsync("https://api.anthropic.com/v1/messages", body, headers, ct);

        if (obj.TryGetProperty("error", out var err) && err.TryGetProperty("message", out var msg))
            throw new SummaryException($"Claude: {msg.GetString()}");
        if (obj.TryGetProperty("stop_reason", out var stop) && stop.GetString() == "refusal")
            throw new SummaryException("Claude declined to summarize this content");

        var sb = new StringBuilder();
        if (obj.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
            foreach (var block in content.EnumerateArray())
                if (block.TryGetProperty("text", out var t) && t.GetString() is { } s)
                    sb.Append(sb.Length > 0 ? "\n" : "").Append(s);
        return sb.ToString().Trim();
    }

    private async Task<JsonElement> PostAsync(
        string url, object body, (string, string)[]? headers, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"),
        };
        if (headers is not null)
            foreach (var (k, v) in headers)
                req.Headers.TryAddWithoutValidation(k, v);

        using var resp = await http.SendAsync(req, ct);
        var data = await resp.Content.ReadAsStringAsync(ct);
        if ((int)resp.StatusCode >= 400)
        {
            var snippet = data.Length > 300 ? data[..300] : data;
            throw new SummaryException($"HTTP {(int)resp.StatusCode}: {snippet}");
        }
        return JsonDocument.Parse(data).RootElement.Clone();
    }
}