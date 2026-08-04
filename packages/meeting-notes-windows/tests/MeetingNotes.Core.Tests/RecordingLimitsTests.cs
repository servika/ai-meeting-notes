using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// The ceilings that protect a recording from destroying its own WAV. These apply
/// regardless of the auto-stop setting, so their arithmetic is worth pinning down:
/// system audio runs ~1.4 GB/hour, which reaches the 4 GB limit during the third
/// hour - before the 4-hour cap, not after it.
/// </summary>
public sealed class RecordingLimitsTests
{
    // 48 kHz, 2 channels, 32-bit float - the usual WASAPI loopback mix format.
    private const long BytesPerSecond = 48_000 * 2 * 4;

    private static long BytesAfter(TimeSpan t) => (long)(t.TotalSeconds * BytesPerSecond);

    [Fact]
    public void FreshRecordingIsOk()
    {
        var limit = RecordingLimits.Check(BytesAfter(TimeSpan.FromMinutes(45)), TimeSpan.FromMinutes(45));
        Assert.Equal(RecordingLimitState.Ok, limit.State);
        Assert.Equal("", limit.Reason);
    }

    [Fact]
    public void StaysUnderTheRiffCeiling()
    {
        // 4 GiB is where RIFF's unsigned 32-bit sizes wrap; the stop must land below it.
        Assert.True(RecordingLimits.TrackByteLimit < 4L * 1024 * 1024 * 1024);
        Assert.True(RecordingLimits.TrackByteWarning < RecordingLimits.TrackByteLimit);
    }

    [Fact]
    public void WarnsBeforeItStops()
    {
        var warn = RecordingLimits.Check(RecordingLimits.TrackByteWarning, TimeSpan.FromHours(2.6));
        Assert.Equal(RecordingLimitState.Warning, warn.State);
        Assert.Contains("4 GB", warn.Reason);

        var stop = RecordingLimits.Check(RecordingLimits.TrackByteLimit, TimeSpan.FromHours(2.9));
        Assert.Equal(RecordingLimitState.Stop, stop.State);
    }

    [Fact]
    public void SizeLimitArrivesBeforeTheFourHourCap()
    {
        // The regression this guards: relying on the 4-hour cap to keep the file
        // under 4 GB. At the real capture rate it does not.
        var atThreeHours = BytesAfter(TimeSpan.FromHours(3));
        Assert.True(atThreeHours > RecordingLimits.TrackByteLimit);
        Assert.Equal(RecordingLimitState.Stop,
            RecordingLimits.Check(atThreeHours, TimeSpan.FromHours(3)).State);
    }

    [Fact]
    public void DurationCapStillCatchesLowBitrateCaptures()
    {
        // A mono 16-bit device never reaches the byte limit - the hour cap is what
        // ends a recording someone left running overnight.
        var slow = 16_000L * 2 * (long)TimeSpan.FromHours(4).TotalSeconds;
        Assert.True(slow < RecordingLimits.TrackByteLimit);

        var limit = RecordingLimits.Check(slow, TimeSpan.FromHours(4));
        Assert.Equal(RecordingLimitState.Stop, limit.State);
        Assert.Contains("4-hour", limit.Reason);
    }

    [Fact]
    public void StopWinsOverWarning()
    {
        var limit = RecordingLimits.Check(RecordingLimits.TrackByteLimit, TimeSpan.FromHours(3.9));
        Assert.Equal(RecordingLimitState.Stop, limit.State);
    }

    [Fact]
    public void EstimatesTimeLeftFromTheObservedRate()
    {
        var elapsed = TimeSpan.FromHours(2);
        var bytes = BytesAfter(elapsed);
        var left = RecordingLimits.SecondsUntilByteLimit(bytes, elapsed);

        Assert.NotNull(left);
        var expected = (RecordingLimits.TrackByteLimit - bytes) / (double)BytesPerSecond;
        Assert.Equal(expected, left!.Value, 1);
    }

    [Fact]
    public void NoEstimateBeforeThereIsAnythingToExtrapolateFrom()
    {
        Assert.Null(RecordingLimits.SecondsUntilByteLimit(0, TimeSpan.FromMinutes(5)));
        Assert.Null(RecordingLimits.SecondsUntilByteLimit(1024, TimeSpan.Zero));
    }

    [Fact]
    public void EstimateNeverGoesNegativePastTheLimit()
    {
        var left = RecordingLimits.SecondsUntilByteLimit(
            RecordingLimits.TrackByteLimit + 1_000_000, TimeSpan.FromHours(3));
        Assert.Equal(0, left);
    }
}