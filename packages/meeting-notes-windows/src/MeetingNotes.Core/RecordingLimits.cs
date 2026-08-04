namespace MeetingNotes.Core;

/// <summary>Where a running recording stands against the hard limits.</summary>
public enum RecordingLimitState { Ok, Warning, Stop }

/// <summary><see cref="RecordingLimitState"/> plus a reason to show the user.</summary>
public readonly record struct RecordingLimit(RecordingLimitState State, string Reason)
{
    public static readonly RecordingLimit Ok = new(RecordingLimitState.Ok, "");
}

/// <summary>
/// Ceilings a recording must not cross, whatever the user's settings say.
///
/// A WAV's RIFF header stores chunk sizes as unsigned 32-bit values, so 4 GiB is a
/// hard structural limit: past it the sizes wrap and the file reads back as garbage.
/// The captured tracks are written in the device's own format (typically 48 kHz
/// stereo 32-bit float ≈ 1.4 GB/hour for system audio), so that ceiling arrives
/// around the third hour - *before* the 4-hour cap, not after it.
///
/// These are separate from the auto-stop setting on purpose: auto-stop is about
/// forgotten recordings and the user may legitimately turn it off, but a recording
/// that runs past these limits destroys its own audio.
/// </summary>
public static class RecordingLimits
{
    /// <summary>Stop here - a margin under the 4 GiB (4,294,967,296 B) RIFF ceiling.</summary>
    public const long TrackByteLimit = 4_000_000_000;

    /// <summary>Warn from here, ~10 minutes of system audio before the stop.</summary>
    public const long TrackByteWarning = 3_600_000_000;

    /// <summary>Longest recording allowed, in hours.</summary>
    public const double MaxHours = 4;

    /// <summary>Warn from here, in hours.</summary>
    public const double WarningHours = 3.75;

    /// <summary>
    /// Judge a recording by its largest track and how long it has been running.
    /// A Stop always wins over a Warning.
    /// </summary>
    public static RecordingLimit Check(long maxTrackBytes, TimeSpan elapsed)
    {
        if (maxTrackBytes >= TrackByteLimit)
            return new(RecordingLimitState.Stop, "reached the 4 GB limit of the WAV format");
        if (elapsed.TotalHours >= MaxHours)
            return new(RecordingLimitState.Stop, $"{MaxHours:0}-hour limit reached");

        if (maxTrackBytes >= TrackByteWarning)
            return new(RecordingLimitState.Warning, "approaching the 4 GB limit of the WAV format");
        if (elapsed.TotalHours >= WarningHours)
            return new(RecordingLimitState.Warning, $"approaching the {MaxHours:0}-hour limit");

        return RecordingLimit.Ok;
    }

    /// <summary>
    /// Seconds of recording left before <see cref="TrackByteLimit"/>, extrapolated
    /// from the rate so far. Null when it cannot be estimated yet.
    /// </summary>
    public static double? SecondsUntilByteLimit(long maxTrackBytes, TimeSpan elapsed)
    {
        if (maxTrackBytes <= 0 || elapsed.TotalSeconds < 1) return null;
        var bytesPerSecond = maxTrackBytes / elapsed.TotalSeconds;
        if (bytesPerSecond <= 0) return null;
        return Math.Max(0, (TrackByteLimit - maxTrackBytes) / bytesPerSecond);
    }
}