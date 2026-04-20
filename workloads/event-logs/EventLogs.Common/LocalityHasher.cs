using System.IO.Hashing;
using System.Text;

namespace EventLogs.Common;

/// <summary>
/// Computes locality hash matching CockroachDB's crc32ieee() function.
/// This allows client-side determination of which region an account belongs to.
/// </summary>
public static class LocalityHasher
{
    private const int TotalBuckets = 30;

    /// <summary>
    /// Computes the locality bucket (0-29) for a given account ID.
    /// Matches CockroachDB's: mod(crc32ieee(account_id::BYTES), 30)
    /// </summary>
    public static short ComputeLocality(Guid accountId)
    {
        var bytes = accountId.ToByteArray();
        var crc32 = Crc32.Hash(bytes);
        var hash = BitConverter.ToUInt32(crc32, 0);
        return (short)(hash % TotalBuckets);
    }

    /// <summary>
    /// Maps a locality bucket to its region name.
    /// 0-9 → us-east
    /// 10-19 → us-central
    /// 20-29 → us-west
    /// </summary>
    public static string LocalityToRegion(short locality)
    {
        return locality switch
        {
            >= 0 and <= 9 => "us-east",
            >= 10 and <= 19 => "us-central",
            >= 20 and <= 29 => "us-west",
            _ => throw new ArgumentOutOfRangeException(nameof(locality),
                $"Locality must be between 0 and 29, got {locality}")
        };
    }

    /// <summary>
    /// Gets all locality buckets for a given region.
    /// </summary>
    public static short[] GetLocalityBucketsForRegion(string region)
    {
        return region.ToLower() switch
        {
            "us-east" => new short[] { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
            "us-central" => new short[] { 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 },
            "us-west" => new short[] { 20, 21, 22, 23, 24, 25, 26, 27, 28, 29 },
            _ => throw new ArgumentException($"Unknown region: {region}", nameof(region))
        };
    }

    /// <summary>
    /// Determines the region for a given account ID.
    /// </summary>
    public static string GetRegionForAccountId(Guid accountId)
    {
        var locality = ComputeLocality(accountId);
        return LocalityToRegion(locality);
    }
}
