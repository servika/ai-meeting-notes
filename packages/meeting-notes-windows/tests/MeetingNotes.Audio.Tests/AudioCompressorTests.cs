using MeetingNotes.Audio;

namespace MeetingNotes.Audio.Tests;

/// <summary>
/// The audio-retention policy. These tests assert on the files left on disk: the
/// recording is the one thing the app can never re-create, so "which file still
/// exists afterwards" is the contract.
/// </summary>
public class AudioCompressorTests : WavFixture
{
    private string SystemWav => Path_("M.system.wav");
    private string MicWav => Path_("M.mic.wav");
    private string SystemM4A => Path_("M.system.m4a");
    private string MicM4A => Path_("M.mic.m4a");

    private void WriteBothTracks()
    {
        WriteWav("M.system.wav");
        WriteWav("M.mic.wav");
    }

    [Fact]
    public void Original_keeps_both_wavs()
    {
        WriteBothTracks();

        Assert.Equal("wav", AudioCompressor.ApplyRetention(SystemWav, MicWav, "original"));
        Assert.True(File.Exists(SystemWav));
        Assert.True(File.Exists(MicWav));
    }

    [Fact]
    public void An_unknown_policy_is_treated_as_original()
    {
        WriteBothTracks();

        Assert.Equal("wav", AudioCompressor.ApplyRetention(SystemWav, MicWav, "whatever"));
        Assert.True(File.Exists(SystemWav));
    }

    [Fact]
    public void Delete_removes_both_tracks_and_reports_no_extension()
    {
        WriteBothTracks();

        Assert.Null(AudioCompressor.ApplyRetention(SystemWav, MicWav, "delete"));
        Assert.False(File.Exists(SystemWav));
        Assert.False(File.Exists(MicWav));
    }

    [Fact]
    public void Delete_tolerates_tracks_that_are_already_gone()
    {
        Assert.Null(AudioCompressor.ApplyRetention(SystemWav, MicWav, "delete"));
    }

    [Fact]
    public void Compressed_replaces_the_wavs_with_m4as()
    {
        WriteBothTracks();

        Assert.Equal("m4a", AudioCompressor.ApplyRetention(SystemWav, MicWav, "compressed"));
        Assert.False(File.Exists(SystemWav));
        Assert.False(File.Exists(MicWav));
        Assert.True(new FileInfo(SystemM4A).Length > 0);
        Assert.True(new FileInfo(MicM4A).Length > 0);
    }

    [Fact]
    public void Compressed_handles_a_recording_with_only_one_track()
    {
        WriteWav("M.system.wav");

        Assert.Equal("m4a", AudioCompressor.ApplyRetention(SystemWav, MicWav, "compressed"));
        Assert.True(File.Exists(SystemM4A));
        Assert.False(File.Exists(MicM4A));
    }

    [Fact]
    public void Re_running_compression_on_already_compressed_tracks_keeps_them()
    {
        // Regression: re-generating or trimming a compressed meeting used to hand
        // each .m4a to the WAV reader as both input and output, and the failure
        // cleanup then deleted the only copy of the recording.
        WriteBothTracks();
        Assert.Equal("m4a", AudioCompressor.ApplyRetention(SystemWav, MicWav, "compressed"));
        var sizeBefore = new FileInfo(SystemM4A).Length;

        Assert.Equal("m4a", AudioCompressor.ApplyRetention(SystemM4A, MicM4A, "compressed"));

        Assert.True(File.Exists(SystemM4A), "the compressed system track must survive a second pass");
        Assert.True(File.Exists(MicM4A), "the compressed mic track must survive a second pass");
        Assert.Equal(sizeBefore, new FileInfo(SystemM4A).Length);
    }

    [Fact]
    public void Compression_refuses_to_write_onto_its_own_source()
    {
        var wav = WriteWav("solo.wav");

        Assert.False(AudioCompressor.CompressToM4A(wav, wav));
        Assert.True(File.Exists(wav));
    }

    [Fact]
    public void A_failed_encode_never_deletes_a_pre_existing_output_file()
    {
        var junk = Path_("junk.wav");
        File.WriteAllText(junk, "not audio at all");
        var existing = Path_("junk.m4a");
        File.WriteAllText(existing, "someone else's file");

        Assert.False(AudioCompressor.CompressToM4A(junk, existing));
        Assert.True(File.Exists(existing));
    }

    [Fact]
    public void A_failed_encode_cleans_up_its_own_partial_output()
    {
        var junk = Path_("junk.wav");
        File.WriteAllText(junk, "not audio at all");

        Assert.False(AudioCompressor.CompressToM4A(junk, Path_("junk.m4a")));
        Assert.False(File.Exists(Path_("junk.m4a")));
    }

    [Fact]
    public void A_track_that_cannot_be_encoded_stays_a_wav_and_the_note_keeps_wav_links()
    {
        WriteWav("M.system.wav");
        File.WriteAllText(MicWav, "not audio at all");

        Assert.Equal("wav", AudioCompressor.ApplyRetention(SystemWav, MicWav, "compressed"));
        Assert.True(File.Exists(MicWav), "the track we couldn't encode must be left alone");
        Assert.True(File.Exists(SystemM4A));
    }

    [Fact]
    public void Compressed_output_is_smaller_than_the_original_wav()
    {
        var wav = WriteWav("long.wav", seconds: 5);
        var wavSize = new FileInfo(wav).Length;

        Assert.True(AudioCompressor.CompressToM4A(wav, Path_("long.m4a")));
        Assert.True(new FileInfo(Path_("long.m4a")).Length < wavSize);
    }

    [Fact]
    public void Compressed_with_no_audio_at_all_reports_m4a_without_creating_files()
    {
        Assert.Equal("m4a", AudioCompressor.ApplyRetention(SystemWav, MicWav, "compressed"));
        Assert.False(File.Exists(SystemM4A));
        Assert.False(File.Exists(MicM4A));
    }
}