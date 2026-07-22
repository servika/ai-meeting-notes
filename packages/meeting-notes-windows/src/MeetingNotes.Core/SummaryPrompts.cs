namespace MeetingNotes.Core;

/// <summary>Baked-in summary prompts. Port of the macOS Summarizer.defaultPrompt.</summary>
public static class SummaryPrompts
{
    public const string Default =
        "You are summarizing a meeting transcript (lines are labeled You/Them). Respond in clean " +
        "Markdown with EXACTLY these four sections, in this order, and nothing else. Never ask for " +
        "clarification, refuse, or add any preamble or closing remarks:\n\n" +
        "## Short summary\n" +
        "One or two sentences with the single most important outcome.\n\n" +
        "## Summary\n" +
        "One or two short paragraphs: who met, the main topics, key decisions, and the outcome.\n\n" +
        "## Topics discussed\n" +
        "For each distinct topic or block raised, a \"### \" subheading naming the topic, then 1-3 " +
        "short paragraphs and bullet points describing what was said or decided about it.\n\n" +
        "## Action items\n" +
        "- [ ] Each task, with the owner if mentioned. If there are none, write \"- None identified.\"\n\n" +
        "Transcript:\n{{transcript}}";
}