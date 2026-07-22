namespace MeetingNotes.Core;

/// <summary>
/// Trims a WAV recording from the end, for when a user forgot to stop.
/// Operates on 16-bit mono 16 kHz PCM WAV files (the format produced by
/// MeetingRecorder). Port of macOS RecordingController+Trim.swift.
/// </summary>
public static class AudioTrimmer
{
    /// <summary>
    /// Trim <paramref name="wavPath"/> to keep only the first
    /// <paramref name="endSeconds"/> seconds. The file is replaced atomically.
    /// Returns false on failure (original is left untouched).
    /// </summary>
    public static bool TrimWav(string wavPath, double endSeconds)
    {
        if (!File.Exists(wavPath) || endSeconds <= 0) return false;

        var tmp = wavPath + ".trim.tmp";
        try
        {
            using var reader = new BinaryReader(File.OpenRead(wavPath));
            if (new string(reader.ReadChars(4)) != "RIFF") return false;
            reader.ReadInt32(); // file size
            if (new string(reader.ReadChars(4)) != "WAVE") return false;

            int sampleRate = 0, bitsPerSample = 0, channels = 0, dataSize = 0;
            long dataStart = 0;

            while (reader.BaseStream.Position < reader.BaseStream.Length)
            {
                var chunkId = new string(reader.ReadChars(4));
                var chunkSize = reader.ReadInt32();
                if (chunkId == "fmt ")
                {
                    reader.ReadInt16(); // format (1=PCM)
                    channels = reader.ReadInt16();
                    sampleRate = reader.ReadInt32();
                    reader.ReadInt32(); // byte rate
                    reader.ReadInt16(); // block align
                    bitsPerSample = reader.ReadInt16();
                    if (chunkSize > 16) reader.ReadBytes(chunkSize - 16);
                }
                else if (chunkId == "data")
                {
                    dataSize = chunkSize;
                    dataStart = reader.BaseStream.Position;
                    break;
                }
                else
                {
                    reader.ReadBytes(chunkSize);
                }
            }

            if (sampleRate == 0 || dataStart == 0) return false;

            var bytesPerSample = bitsPerSample / 8 * channels;
            var keepSamples = (long)(endSeconds * sampleRate);
            var keepBytes = (int)Math.Min(keepSamples * bytesPerSample, dataSize);

            if (keepBytes >= dataSize) return true; // nothing to trim

            reader.BaseStream.Seek(dataStart, SeekOrigin.Begin);
            var audioData = reader.ReadBytes(keepBytes);
            reader.Close();

            using var writer = new BinaryWriter(File.Create(tmp));
            var totalDataSize = keepBytes;
            writer.Write("RIFF"u8);
            writer.Write(36 + totalDataSize);
            writer.Write("WAVE"u8);
            writer.Write("fmt "u8);
            writer.Write(16); // chunk size
            writer.Write((short)1); // PCM
            writer.Write((short)channels);
            writer.Write(sampleRate);
            writer.Write(sampleRate * channels * (bitsPerSample / 8));
            writer.Write((short)(channels * (bitsPerSample / 8)));
            writer.Write((short)bitsPerSample);
            writer.Write("data"u8);
            writer.Write(totalDataSize);
            writer.Write(audioData);
            writer.Close();

            File.Move(tmp, wavPath, overwrite: true);
            return true;
        }
        catch
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            return false;
        }
    }

    /// <summary>Duration of a WAV file in seconds, or 0 on error.</summary>
    public static double GetDurationSeconds(string wavPath)
    {
        if (!File.Exists(wavPath)) return 0;
        try
        {
            using var reader = new BinaryReader(File.OpenRead(wavPath));
            if (new string(reader.ReadChars(4)) != "RIFF") return 0;
            reader.ReadInt32();
            if (new string(reader.ReadChars(4)) != "WAVE") return 0;

            int sampleRate = 0, bitsPerSample = 0, channels = 0, dataSize = 0;
            while (reader.BaseStream.Position < reader.BaseStream.Length)
            {
                var chunkId = new string(reader.ReadChars(4));
                var chunkSize = reader.ReadInt32();
                if (chunkId == "fmt ")
                {
                    reader.ReadInt16();
                    channels = reader.ReadInt16();
                    sampleRate = reader.ReadInt32();
                    reader.ReadInt32();
                    reader.ReadInt16();
                    bitsPerSample = reader.ReadInt16();
                    if (chunkSize > 16) reader.ReadBytes(chunkSize - 16);
                }
                else if (chunkId == "data")
                {
                    dataSize = chunkSize;
                    break;
                }
                else
                {
                    reader.ReadBytes(chunkSize);
                }
            }

            if (sampleRate == 0 || channels == 0 || bitsPerSample == 0) return 0;
            var bytesPerSample = bitsPerSample / 8 * channels;
            return (double)dataSize / bytesPerSample / sampleRate;
        }
        catch { return 0; }
    }

    /// <summary>
    /// Update the <c>duration:</c> line in a note's YAML frontmatter.
    /// Port of macOS RecordingController.updateFrontmatterDuration.
    /// </summary>
    public static void UpdateFrontmatterDuration(string notePath, int seconds)
    {
        if (!File.Exists(notePath)) return;
        var content = File.ReadAllText(notePath);
        if (!content.StartsWith("---", StringComparison.Ordinal)) return;

        var lines = content.Split('\n');
        for (var i = 1; i < lines.Length; i++)
        {
            if (lines[i].TrimEnd('\r') == "---") return;
            if (lines[i].StartsWith("duration:", StringComparison.Ordinal))
            {
                lines[i] = $"duration: {seconds}";
                File.WriteAllText(notePath, string.Join('\n', lines));
                return;
            }
        }
    }
}
