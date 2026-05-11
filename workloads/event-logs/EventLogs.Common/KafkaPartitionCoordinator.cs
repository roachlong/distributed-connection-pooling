using Microsoft.Extensions.Logging;
using Npgsql;

namespace EventLogs.Common;

/// <summary>
/// Coordinates Kafka partition assignments across multiple consumer instances
/// using CockroachDB as the coordination service. Guarantees exactly-one-consumer
/// per partition with automatic failover.
/// </summary>
public class KafkaPartitionCoordinator : IAsyncDisposable
{
    private readonly string _connectionString;
    private readonly string _consumerId;
    private readonly string _hostname;
    private readonly string _topic;
    private readonly int _partitionCount;
    private readonly int _maxPartitionsPerConsumer;
    private readonly TimeSpan _heartbeatInterval;
    private readonly ILogger _logger;

    private readonly HashSet<int> _ownedPartitions = new();
    private readonly SemaphoreSlim _lock = new(1, 1);
    private CancellationTokenSource? _heartbeatCts;
    private Task? _heartbeatTask;
    private Task? _claimTask;

    public KafkaPartitionCoordinator(
        string connectionString,
        string topic,
        int partitionCount,
        int maxPartitionsPerConsumer,
        ILogger logger)
    {
        _connectionString = connectionString;
        _topic = topic;
        _partitionCount = partitionCount;
        _maxPartitionsPerConsumer = maxPartitionsPerConsumer;
        _logger = logger;

        _consumerId = Guid.NewGuid().ToString();
        _hostname = Environment.MachineName;
        _heartbeatInterval = TimeSpan.FromSeconds(10);
    }

    /// <summary>
    /// Starts the coordinator - registers consumer and begins claiming partitions
    /// </summary>
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        // Register this consumer instance
        await RegisterConsumerAsync();

        // Start background tasks
        _heartbeatCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        _heartbeatTask = Task.Run(() => HeartbeatLoopAsync(_heartbeatCts.Token), _heartbeatCts.Token);
        _claimTask = Task.Run(() => ClaimPartitionsLoopAsync(_heartbeatCts.Token), _heartbeatCts.Token);

        _logger.LogInformation("KafkaPartitionCoordinator started: {ConsumerId} on {Hostname}",
            _consumerId, _hostname);
    }

    /// <summary>
    /// Checks if this consumer owns the specified partition
    /// </summary>
    public bool OwnsPartition(int partitionId)
    {
        lock (_ownedPartitions)
        {
            return _ownedPartitions.Contains(partitionId);
        }
    }

    /// <summary>
    /// Gets the list of partitions currently owned by this consumer
    /// </summary>
    public int[] GetOwnedPartitions()
    {
        lock (_ownedPartitions)
        {
            return _ownedPartitions.ToArray();
        }
    }

    /// <summary>
    /// Reports that a message was successfully processed (updates offset tracking)
    /// </summary>
    public async Task ReportMessageProcessedAsync(int partitionId, long offset)
    {
        if (!OwnsPartition(partitionId))
        {
            _logger.LogWarning("Attempted to report message for unowned partition {Partition}", partitionId);
            return;
        }

        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(@"
            UPDATE kafka_partition_assignments
            SET last_offset = @offset,
                last_processed_at = now(),
                messages_processed = messages_processed + 1
            WHERE topic = @topic
              AND partition_id = @partition
              AND consumer_id = @consumerId", conn);

        cmd.Parameters.AddWithValue("topic", _topic);
        cmd.Parameters.AddWithValue("partition", partitionId);
        cmd.Parameters.AddWithValue("offset", offset);
        cmd.Parameters.AddWithValue("consumerId", _consumerId);

        await cmd.ExecuteNonQueryAsync();
    }

    // =============================================================================
    // Private Methods
    // =============================================================================

    private async Task RegisterConsumerAsync()
    {
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(@"
            INSERT INTO kafka_consumers (consumer_id, hostname, process_id, started_at, last_heartbeat, partition_capacity)
            VALUES (@consumerId, @hostname, @processId, now(), now(), @capacity)
            ON CONFLICT (consumer_id) DO UPDATE SET
                last_heartbeat = now(),
                is_healthy = true", conn);

        cmd.Parameters.AddWithValue("consumerId", _consumerId);
        cmd.Parameters.AddWithValue("hostname", _hostname);
        cmd.Parameters.AddWithValue("processId", Environment.ProcessId);
        cmd.Parameters.AddWithValue("capacity", _maxPartitionsPerConsumer);

        await cmd.ExecuteNonQueryAsync();

        _logger.LogInformation("Consumer registered: {ConsumerId}", _consumerId);
    }

    private async Task ClaimPartitionsLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await ClaimAvailablePartitionsAsync();
                await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error in partition claim loop");
                await Task.Delay(TimeSpan.FromSeconds(10), cancellationToken);
            }
        }
    }

    private async Task ClaimAvailablePartitionsAsync()
    {
        await _lock.WaitAsync();
        try
        {
            await using var conn = new NpgsqlConnection(_connectionString);
            await conn.OpenAsync();

            // Calculate fair share of partitions for load balancing
            var (totalConsumers, fairShare) = await CalculateFairShareAsync(conn);

            var currentCount = _ownedPartitions.Count;

            // Rebalancing: if we have more than fair share, release excess
            if (currentCount > fairShare)
            {
                var excessCount = currentCount - fairShare;
                var partitionsToRelease = GetOwnedPartitions()
                    .OrderByDescending(p => p) // Release highest partition IDs first
                    .Take(excessCount)
                    .ToList();

                foreach (var partitionId in partitionsToRelease)
                {
                    await ReleasePartitionAsync(partitionId, "rebalance");
                    _logger.LogInformation("Released partition {Topic}/{Partition} for rebalancing ({Current} -> {Target})",
                        _topic, partitionId, currentCount, fairShare);
                }

                return; // Don't claim new partitions in same iteration after releasing
            }

            // Don't claim beyond fair share (unless no other healthy consumers)
            var targetCapacity = totalConsumers > 0 ? fairShare : _maxPartitionsPerConsumer;
            if (currentCount >= targetCapacity)
            {
                return; // Already at target capacity
            }

            // Find orphaned partitions (no consumer or dead consumer)
            await using var findCmd = new NpgsqlCommand(@"
                SELECT partition_id
                FROM kafka_partition_assignments
                WHERE topic = @topic
                  AND partition_id < @partitionCount
                  AND (
                      consumer_id IS NULL
                      OR (last_heartbeat IS NOT NULL AND now() - last_heartbeat > INTERVAL '30 seconds')
                  )
                  AND partition_id NOT IN (
                      SELECT partition_id FROM kafka_partition_assignments
                      WHERE topic = @topic AND consumer_id = @consumerId
                  )
                ORDER BY reassignment_count ASC, partition_id ASC
                LIMIT @limit", conn);

            findCmd.Parameters.AddWithValue("topic", _topic);
            findCmd.Parameters.AddWithValue("partitionCount", _partitionCount);
            findCmd.Parameters.AddWithValue("consumerId", _consumerId);
            findCmd.Parameters.AddWithValue("limit", targetCapacity - currentCount);

            var orphanedPartitions = new List<int>();
            await using (var reader = await findCmd.ExecuteReaderAsync())
            {
                while (await reader.ReadAsync())
                {
                    orphanedPartitions.Add(reader.GetInt32(0));
                }
            }

            // Try to claim each orphaned partition
            foreach (var partitionId in orphanedPartitions)
            {
                if (await TryClaimPartitionAsync(conn, partitionId))
                {
                    lock (_ownedPartitions)
                    {
                        _ownedPartitions.Add(partitionId);
                    }

                    _logger.LogInformation("Claimed partition {Topic}/{Partition} ({Current}/{Target})",
                        _topic, partitionId, _ownedPartitions.Count, targetCapacity);
                }
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task<(int totalConsumers, int fairShare)> CalculateFairShareAsync(NpgsqlConnection conn)
    {
        // Count healthy consumers working on THIS topic (heartbeat within last 30 seconds)
        await using var cmd = new NpgsqlCommand(@"
            SELECT COUNT(DISTINCT kpa.consumer_id)
            FROM kafka_partition_assignments kpa
            JOIN kafka_consumers kc ON kpa.consumer_id = kc.consumer_id
            WHERE kpa.topic = @topic
              AND kc.is_healthy = true
              AND now() - kc.last_heartbeat < INTERVAL '30 seconds'", conn);

        cmd.Parameters.AddWithValue("topic", _topic);

        var totalConsumers = Convert.ToInt32(await cmd.ExecuteScalarAsync() ?? 0);
        var fairShare = totalConsumers > 0 ? (_partitionCount + totalConsumers - 1) / totalConsumers : _maxPartitionsPerConsumer;

        return (totalConsumers, fairShare);
    }

    private async Task<bool> TryClaimPartitionAsync(NpgsqlConnection conn, int partitionId)
    {
        try
        {
            await using var cmd = new NpgsqlCommand(@"
                SELECT claim_partition(@topic, @partition, @consumerId, @hostname)", conn);

            cmd.Parameters.AddWithValue("topic", _topic);
            cmd.Parameters.AddWithValue("partition", partitionId);
            cmd.Parameters.AddWithValue("consumerId", _consumerId);
            cmd.Parameters.AddWithValue("hostname", _hostname);

            var result = await cmd.ExecuteScalarAsync();
            return result is bool success && success;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to claim partition {Partition}", partitionId);
            return false;
        }
    }

    private async Task HeartbeatLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await SendHeartbeatAsync();
                await Task.Delay(_heartbeatInterval, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error in heartbeat loop");
                await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
            }
        }
    }

    private async Task SendHeartbeatAsync()
    {
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync();

        // Update consumer heartbeat
        await using var consumerCmd = new NpgsqlCommand(@"
            UPDATE kafka_consumers
            SET last_heartbeat = now(),
                is_healthy = true,
                consecutive_failures = 0
            WHERE consumer_id = @consumerId", conn);

        consumerCmd.Parameters.AddWithValue("consumerId", _consumerId);
        await consumerCmd.ExecuteNonQueryAsync();

        // Update partition heartbeats
        var ownedPartitionIds = GetOwnedPartitions();
        if (ownedPartitionIds.Length > 0)
        {
            await using var partitionCmd = new NpgsqlCommand(@"
                UPDATE kafka_partition_assignments
                SET last_heartbeat = now()
                WHERE topic = @topic
                  AND consumer_id = @consumerId
                  AND partition_id = ANY(@partitions)", conn);

            partitionCmd.Parameters.AddWithValue("topic", _topic);
            partitionCmd.Parameters.AddWithValue("consumerId", _consumerId);
            partitionCmd.Parameters.AddWithValue("partitions", ownedPartitionIds);

            await partitionCmd.ExecuteNonQueryAsync();
        }
    }

    public async ValueTask DisposeAsync()
    {
        _logger.LogInformation("Shutting down coordinator gracefully...");

        // Stop background tasks
        _heartbeatCts?.Cancel();

        if (_heartbeatTask != null)
            await _heartbeatTask;
        if (_claimTask != null)
            await _claimTask;

        // Release all owned partitions
        foreach (var partitionId in GetOwnedPartitions())
        {
            await ReleasePartitionAsync(partitionId, "graceful_shutdown");
        }

        // Mark consumer as unhealthy
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(@"
            UPDATE kafka_consumers
            SET is_healthy = false,
                current_partitions = 0
            WHERE consumer_id = @consumerId", conn);

        cmd.Parameters.AddWithValue("consumerId", _consumerId);
        await cmd.ExecuteNonQueryAsync();

        _logger.LogInformation("Coordinator shutdown complete");
    }

    private async Task ReleasePartitionAsync(int partitionId, string reason)
    {
        try
        {
            await using var conn = new NpgsqlConnection(_connectionString);
            await conn.OpenAsync();

            await using var cmd = new NpgsqlCommand(@"
                SELECT release_partition(@topic, @partition, @consumerId, @reason)", conn);

            cmd.Parameters.AddWithValue("topic", _topic);
            cmd.Parameters.AddWithValue("partition", partitionId);
            cmd.Parameters.AddWithValue("consumerId", _consumerId);
            cmd.Parameters.AddWithValue("reason", reason);

            await cmd.ExecuteNonQueryAsync();

            lock (_ownedPartitions)
            {
                _ownedPartitions.Remove(partitionId);
            }

            _logger.LogInformation("Released partition {Topic}/{Partition} (reason: {Reason})",
                _topic, partitionId, reason);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to release partition {Partition}", partitionId);
        }
    }
}
