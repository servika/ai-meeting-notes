using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

public class AudioTrimmerTests
{
    // 16-bit mono PCM WAV at the given sample rate, `seconds` long, each sample set
    // to its frame index so we can assert exactly which range survived a trim.
    private static string WriteRampWav(int sampleRate, int seconds)
    {
        var path = Path.Combine(Path.GetTempPath(), $"trim-{Guid.NewGuid():N}.wav");
        var totalSamples = sampleRate * seconds;
        var dataSize = totalSamples * 2;
        using var w = new BinaryWriter(File.Create(path));
        w.Write("RIFF"u8);
        w.Write(36 + dataSize);
        w.Write("WAVE"u8);
        w.Write("fmt "u8);
        w.Write(16);
        w.Write((short)1);            // PCM
        w.Write((short)1);            // mono
        w.Write(sampleRate);
        w.Write(sampleRate * 2);      // byte rate
        w.Write((short)2);            // block align
        w.Write((short)16);           // bits
        w.Write("data"u8);
        w.Write(dataSize);
        for (var i = 0; i < totalSamples; i++) w.Write((short)(i % short.MaxValue));
        return path;
    }

    private static short[] ReadSamples(string path)
    {
        using var r = new BinaryReader(File.OpenRead(path));
        r.ReadChars(4); r.ReadInt32(); r.ReadChars(4); // RIFF/size/WAVE
        int dataSize = 0;
        while (r.BaseStream.Position < r.BaseStream.Length)
        {
            var id = new string(r.ReadChars(4));
            var size = r.ReadInt32();
            if (id == "data") { dataSize = size; break; }
            r.ReadBytes(size);
        }
        var samples = new short[dataSize / 2];
        for (var i = 0; i < samples.Length; i++) samples[i] = r.ReadInt16();
        return samples;
    }

    [Fact]
    public void TrimWav_start_and_end_keeps_only_the_middle()
    {
        var path = WriteRampWav(1000, 10); // 10s, 1 kHz → 10000 samples
        try
        {
            // Keep [2s, 7s) → samples 2000..6999 (5000 samples).
            Assert.True(AudioTrimmer.TrimWav(path, 2.0, 7.0));

            var samples = ReadSamples(path);
            Assert.Equal(5000, samples.Length);
            Assert.Equal(2000 % short.MaxValue, samples[0]);
            Assert.Equal(6999 % short.MaxValue, samples[^1]);
            Assert.Equal(5.0, AudioTrimmer.GetDurationSeconds(path), 3);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void TrimWav_endOnly_overload_keeps_the_head()
    {
        var path = WriteRampWav(1000, 10);
        try
        {
            Assert.True(AudioTrimmer.TrimWav(path, 4.0)); // first 4s
            var samples = ReadSamples(path);
            Assert.Equal(4000, samples.Length);
            Assert.Equal(0, samples[0]);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void TrimWav_rejects_inverted_or_empty_range()
    {
        var path = WriteRampWav(1000, 10);
        try
        {
            Assert.False(AudioTrimmer.TrimWav(path, 5.0, 5.0)); // zero-length
            Assert.False(AudioTrimmer.TrimWav(path, 8.0, 3.0)); // end before start
            Assert.Equal(10000, ReadSamples(path).Length);      // original untouched
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void TrimWav_full_range_is_a_noop_success()
    {
        var path = WriteRampWav(1000, 10);
        try
        {
            Assert.True(AudioTrimmer.TrimWav(path, 0.0, 20.0)); // end past duration
            Assert.Equal(10000, ReadSamples(path).Length);
        }
        finally { File.Delete(path); }
    }
}