using MeetingNotes.Core;

namespace MeetingNotes.Core.Tests;

/// <summary>
/// Version comparison behind the "update available" banner. The HTTP call itself
/// isn't exercised here - only the ordering that decides whether users are told
/// about a release.
/// </summary>
public class UpdateCheckerTests
{
    [Theory]
    [InlineData("0.5.1", "0.5.0")]
    [InlineData("0.6.0", "0.5.9")]
    [InlineData("1.0.0", "0.99.99")]
    [InlineData("0.5", "0.4.9")]
    [InlineData("0.5.1", "0.5")]
    public void IsNewer_is_true_for_a_higher_version(string a, string b) =>
        Assert.True(UpdateChecker.IsNewer(a, b));

    [Theory]
    [InlineData("0.5.0", "0.5.0")]
    [InlineData("0.5.0", "0.5.1")]
    [InlineData("0.5", "0.5.0")]
    [InlineData("0.9.9", "1.0.0")]
    public void IsNewer_is_false_for_the_same_or_an_older_version(string a, string b) =>
        Assert.False(UpdateChecker.IsNewer(a, b));

    [Fact]
    public void IsNewer_ignores_any_suffix_after_the_numbers()
    {
        Assert.True(UpdateChecker.IsNewer("0.6.0-beta", "0.5.0"));
        Assert.False(UpdateChecker.IsNewer("0.5.0-rc1", "0.5.0"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-version")]
    public void IsNewer_never_claims_garbage_is_newer(string a) =>
        Assert.False(UpdateChecker.IsNewer(a, "0.5.0"));

    [Fact]
    public void A_fresh_checker_reports_no_update()
    {
        var checker = new UpdateChecker();

        Assert.Null(checker.LatestVersion);
        Assert.Null(checker.ReleaseUrl);
        Assert.False(checker.UpdateAvailable);
    }

    [Fact]
    public void The_shipped_version_is_not_newer_than_itself()
    {
        // Guards against a malformed VERSION file making the app nag about itself.
        Assert.False(UpdateChecker.IsNewer(BuildInfo.Version, BuildInfo.Version));
    }
}