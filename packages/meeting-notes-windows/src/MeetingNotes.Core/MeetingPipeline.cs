namespace MeetingNotes.Core;

/// <summary>What to run after a recording stops, plus the inputs each stage needs.</summary>
public sealed record PipelineOptions
{
    public bool Transcribe { get; init; } = true;
    public bool Summarize { get; init; } = true;
    public string Language { get; init; } = "auto";
    public string WhisperModelPath { get; init; } = "";
    public string SummaryPrompt { get; init; } = "";
    public SummaryEngine? Engine { get; init; }
    public string AppVersion { get; init; } = "0.1.0";
    /// <summary>"original" keeps WAV, "compressed" → M4A, "delete" removes audio after transcription.</summary>
    public string AudioRetention { get; init; } = "original";
}

/// <summary>Live progress from the pipeline, passed to the UI via IProgress.</summary>
public sealed record PipelineProgress(double Fraction, string Status);

/// <summary>Result of pipeline processing.</summary>
public sealed record PipelineResult(string NotePath, string? SummaryWarning = null);

/// <summary>
/// Headless processing pipeline: takes the two captured tracks and produces the
/// Obsidian note. Mirrors the macOS RecordingController stages - transcribe each
/// track (You = mic, Them = system), merge into a labeled transcript, summarize,
/// then write the note.
/// </summary>
public sealed class MeetingPipeline(
    WhisperTranscriber transcriber, Summarizer summarizer, MeetingStore store)
{
    /// <summary>Process a finished recording into a note; returns the note's path.</summary>
    public async Task<PipelineResult> ProcessAsync(
        string systemWav, string micWav, string title, DateTime date, string audioBase,
        int durationSeconds, int speakerCount, PipelineOptions opts,
        CancellationToken ct = default, IProgress<PipelineProgress>? progress = null)
    {
        var transcript = "";
        var summary = "";
        string? summaryWarning = null;

        if (opts.Transcribe)
        {
            progress?.Report(new(0.05, "Transcribing microphone…"));
            var segments = new List<TranscriptSegment>();
            if (File.Exists(micWav))
                segments.AddRange(await transcriber.TranscribeAsync(micWav, opts.WhisperModelPath, "You", opts.Language, ct));

            progress?.Report(new(0.45, "Transcribing system audio…"));
            if (File.Exists(systemWav))
                segments.AddRange(await transcriber.TranscribeAsync(systemWav, opts.WhisperModelPath, "Them", opts.Language, ct));

            progress?.Report(new(0.85, "Merging tracks…"));
            segments = Transcriber.RemoveCrossTrackEchoes(segments);
            transcript = Transcriber.DiarizedMarkdown(segments);

            // Save the note with transcript before attempting summarization so
            // data is never lost if the LLM call fails or times out.
            if (transcript.Length > 0)
            {
                progress?.Report(new(0.87, "Saving transcript…"));
                store.WriteNote(title, date, audioBase, durationSeconds, speakerCount,
                    "", transcript, opts.AppVersion);
            }

            if (opts.Summarize && opts.Engine is not null && transcript.Length > 0)
            {
                progress?.Report(new(0.90, "Summarizing…"));
                try
                {
                    var sumProgress = progress is not null
                        ? new Progress<string>(s => progress.Report(new(0.90, s)))
                        : null;
                    summary = await summarizer.SummarizeAsync(
                        transcript, opts.SummaryPrompt, opts.Engine, ct, sumProgress);
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex)
                {
                    summaryWarning = $"Summarization failed: {ex.Message}. Transcript was saved.";
                }
            }
        }

        progress?.Report(new(0.98, "Saving note…"));
        var path = store.WriteNote(
            title, date, audioBase, durationSeconds, speakerCount,
            summary, transcript, opts.AppVersion);
        return new PipelineResult(path, summaryWarning);
    }
}
