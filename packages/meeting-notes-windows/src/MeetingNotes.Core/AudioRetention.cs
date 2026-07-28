namespace MeetingNotes.Core;

/// <summary>
/// The post-transcription audio-retention step: apply the policy to the two
/// tracks, then bring the note's embeds in line with what survived.
/// <para>
/// The encoder itself is Windows-only (Media Foundation), so it is injected -
/// which also keeps this step, and the decision of which files get deleted,
/// testable on any platform. <see cref="MeetingNotes.Audio.AudioCompressor"/>
/// supplies the real encoder.
/// </para>
/// </summary>
public static class AudioRetention
{
    /// <summary>
    /// Apply <paramref name="policy"/> ("original", "compressed" or "delete") to
    /// both tracks. Returns the extension the note should embed ("wav"/"m4a"), or
    /// null when the audio was deleted.
    /// </summary>
    public static string? Apply(
        string systemTrack, string micTrack, string policy, Func<string, string, bool> compressToM4A)
    {
        switch (policy)
        {
            case "delete":
                TryDelete(systemTrack);
                TryDelete(micTrack);
                return null;

            case "compressed":
                foreach (var track in new[] { systemTrack, micTrack })
                {
                    // Already compressed - a re-generate or trim re-runs the pipeline on
                    // the .m4a tracks, and handing one to the WAV encoder would fail and
                    // take the only copy of the recording with it.
                    if (!IsWav(track) || !File.Exists(track)) continue;
                    var m4a = Path.ChangeExtension(track, ".m4a");
                    if (compressToM4A(track, m4a)) TryDelete(track);
                }
                // Notes must link to what survived: if any track is still WAV (encode
                // failed, or it never compressed), keep the note on .wav links.
                var stillWav = new[] { systemTrack, micTrack }.Any(p => IsWav(p) && File.Exists(p));
                return stillWav ? "wav" : "m4a";

            default: // "original"
                return "wav";
        }
    }

    /// <summary>
    /// Rewrite the note's "## Audio" section for the extension the tracks ended up
    /// with - the note was written with .wav links before the policy ran. A missing
    /// note is a no-op.
    /// </summary>
    public static void RewriteNote(string notePath, string audioBase, string? audioExt)
    {
        if (!File.Exists(notePath)) return;
        var audioName = audioBase.Contains('/')
            ? audioBase[(audioBase.LastIndexOf('/') + 1)..]
            : audioBase;
        var content = File.ReadAllText(notePath);
        var rewritten = NoteFormat.RewriteAudioSection(content, audioName, audioExt);
        if (rewritten != content) File.WriteAllText(notePath, rewritten);
    }

    /// <summary>
    /// Locate a meeting's two tracks under <paramref name="vaultDir"/>, preferring
    /// the original WAV and falling back to the compressed M4A. Either side is null
    /// when that track doesn't exist (audio deleted, or only one side was captured).
    /// </summary>
    public static (string? System, string? Mic) FindTracks(string vaultDir, string audioBase)
    {
        string? system = null, mic = null;
        var rel = audioBase.Replace('/', Path.DirectorySeparatorChar);
        foreach (var ext in new[] { "wav", "m4a" })
        {
            var s = Path.Combine(vaultDir, rel + ".system." + ext);
            var m = Path.Combine(vaultDir, rel + ".mic." + ext);
            if (system is null && File.Exists(s)) system = s;
            if (mic is null && File.Exists(m)) mic = m;
        }
        return (system, mic);
    }

    public static bool IsWav(string path) =>
        path.EndsWith(".wav", StringComparison.OrdinalIgnoreCase);

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }
}