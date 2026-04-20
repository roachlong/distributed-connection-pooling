namespace EventLogs.Common;

/// <summary>
/// Configuration for regional deployment.
/// Each app instance is configured for a specific region.
/// </summary>
public class RegionalConfig
{
    /// <summary>
    /// The region this app instance is deployed in (us-east, us-central, us-west).
    /// </summary>
    public string Region { get; set; } = "us-east";

    /// <summary>
    /// Locality buckets owned by this region.
    /// us-east: 0-9, us-central: 10-19, us-west: 20-29
    /// </summary>
    public short[] LocalityBuckets { get; set; } = Array.Empty<short>();

    /// <summary>
    /// Connection string to regional PgBouncer/gateway.
    /// Should route to LTM VIP → PgBouncer → CRDB Gateway in this region.
    /// </summary>
    public string ConnectionString { get; set; } = string.Empty;

    /// <summary>
    /// Kafka bootstrap servers.
    /// </summary>
    public string KafkaBootstrapServers { get; set; } = "localhost:9092";

    /// <summary>
    /// Regional Kafka topic name (e.g., "request-events.us-east").
    /// </summary>
    public string KafkaTopic { get; set; } = string.Empty;

    /// <summary>
    /// Validates that the configuration is complete.
    /// </summary>
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Region))
            throw new InvalidOperationException("Region must be configured");

        if (LocalityBuckets == null || LocalityBuckets.Length == 0)
            throw new InvalidOperationException("LocalityBuckets must be configured");

        if (string.IsNullOrWhiteSpace(ConnectionString))
            throw new InvalidOperationException("ConnectionString must be configured");

        // Verify locality buckets match region
        var expectedBuckets = LocalityHasher.GetLocalityBucketsForRegion(Region);
        if (!LocalityBuckets.OrderBy(b => b).SequenceEqual(expectedBuckets.OrderBy(b => b)))
        {
            throw new InvalidOperationException(
                $"LocalityBuckets {string.Join(",", LocalityBuckets)} do not match region {Region}. " +
                $"Expected: {string.Join(",", expectedBuckets)}");
        }
    }
}
