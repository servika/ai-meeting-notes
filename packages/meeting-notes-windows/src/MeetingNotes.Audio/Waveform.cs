using NAudio.Wave;

namespace MeetingNotes.Audio;

/// <summary>
/// Loudness envelope of a meeting's audio for the Trim window: the tracks are
/// decoded once into a fixed number of RMS buckets (combined across tracks by
/// max, normalized to the loudest bucket) so the view can show at a glance where
/// the recording goes quiet - typically where the meeting really ended.
/// Port of the macOS TrimWaveform.
/// </summary>
public static class Waveform
{
    /// <summary>
    /// Quiet-bucket threshold on the normalized (square-root-compressed) envelope.
    /// ~0.02 of peak RMS (roughly -34 dB) - room noise after everyone left.
    /// </summary>
    public const float QuietLevel = 0.15f;

    /// <summary>
    /// Compute the normalized envelope. Returns an empty array when nothing could
    /// be read (the view then just doesn't render). Decode is CPU-bound, so call
    /// this off the UI thread.
    /// </summary>
    public static float[] Compute(IEnumerable<string> paths, int buckets)
    {
        if (buckets <= 0) return [];
        var combined = new float[buckets];
        var any = false;
        foreach (var path in paths)
        {
            var levels = TrackLevels(path, buckets);
            if (levels is null) continue;
            any = true;
            // Tracks play mixed, so the envelope keeps whichever side is louder.
            for (var i = 0; i < buckets; i++) combined[i] = Math.Max(combined[i], levels[i]);
        }

        if (!any) return [];
        var peak = combined.Max();
        if (peak <= 0) return [];

        // Square root compresses the range so normal speech doesn't make everything
        // but the single loudest moment look near-silent.
        for (var i = 0; i < buckets; i++) combined[i] = MathF.Sqrt(combined[i] / peak);
        return combined;
    }

    /// <summary>Per-bucket RMS of one track. AudioFileReader decodes WAV/M4A alike.</summary>
    private static float[]? TrackLevels(string path, int buckets)
    {
        if (!File.Exists(path)) return null;
        try
        {
            using var reader = new AudioFileReader(path);
            var channels = reader.WaveFormat.Channels;
            if (channels <= 0) return null;
            // AudioFileReader yields 32-bit float samples, so 4 bytes per sample.
            var totalFrames = reader.Length / 4 / channels;
            if (totalFrames <= 0) return null;

            var sumSquares = new double[buckets];
            var counts = new long[buckets];
            var buf = new float[16384 * channels];
            long frame = 0;
            int read;
            while ((read = reader.Read(buf, 0, buf.Length)) > 0)
            {
                var frames = read / channels;
                for (var i = 0; i < frames; i++)
                {
                    var pos = frame + i;
                    var bucket = (int)Math.Min(pos * buckets / totalFrames, buckets - 1);
                    // Loudness only needs one channel - a meeting track carries the
                    // same voice on all of them.
                    var s = buf[i * channels];
                    sumSquares[bucket] += (double)s * s;
                    counts[bucket]++;
                }
                frame += frames;
            }

            var result = new float[buckets];
            for (var i = 0; i < buckets; i++)
                result[i] = counts[i] > 0 ? (float)Math.Sqrt(sumSquares[i] / counts[i]) : 0;
            return result;
        }
        catch { return null; }
    }
}