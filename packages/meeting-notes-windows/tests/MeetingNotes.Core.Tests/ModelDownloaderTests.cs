using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

public class ModelDownloaderTests
{
    [Fact]
    public void FileName_and_Url_match_huggingface_layout()
    {
        Assert.Equal("ggml-base.en.bin", ModelDownloader.FileName("base.en"));
        Assert.Equal(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            ModelDownloader.ModelUrl("large-v3-turbo"));
    }

    [Fact]
    public void ModelPath_lives_under_models_dir()
    {
        var path = ModelDownloader.ModelPath("small");
        Assert.Equal(ModelDownloader.ModelsDir, Path.GetDirectoryName(path));
        Assert.EndsWith("ggml-small.bin", path);
    }

    [Fact]
    public void Available_lists_the_expected_models()
    {
        Assert.Contains("base", ModelDownloader.Available);
        Assert.Contains("large-v3-turbo", ModelDownloader.Available);
    }
}