using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

public class BuildInfoTests
{
    [Fact]
    public void Name_is_set()
    {
        Assert.False(string.IsNullOrWhiteSpace(BuildInfo.Name));
    }

    [Fact]
    public void Version_is_not_empty_and_looks_like_semver()
    {
        Assert.False(string.IsNullOrWhiteSpace(BuildInfo.Version));
        Assert.Contains('.', BuildInfo.Version);
    }
}