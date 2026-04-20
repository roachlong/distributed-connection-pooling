using Microsoft.Extensions.Logging;
using Npgsql;

namespace EventLogs.Common;

/// <summary>
/// Provides comprehensive retry logic for CockroachDB operations.
/// Handles serialization errors (40001), ambiguous results (40003),
/// connection errors (08xx/57xx), and duplicate key violations (23505).
///
/// See RETRY_ERRORS_GUIDE.md for detailed error handling documentation.
/// </summary>
public static class DatabaseRetryHelper
{
    public static async Task<T> ExecuteWithRetryAsync<T>(
        Func<Task<T>> operation,
        ILogger logger,
        string operationName = "database operation",
        int maxRetries = 10,
        CancellationToken cancellationToken = default)
    {
        var retryAttempt = 0;

        while (retryAttempt <= maxRetries)
        {
            try
            {
                return await operation();
            }
            catch (PostgresException ex) when (ex.SqlState == "40001")
            {
                // 40001 - Serialization failure - SAFE TO RETRY
                retryAttempt++;
                if (retryAttempt > maxRetries)
                {
                    logger.LogError(ex, "{Operation} failed after {MaxRetries} serialization retries (40001)",
                        operationName, maxRetries);
                    throw;
                }

                var delayMs = CalculateBackoffMs(retryAttempt);
                logger.LogWarning("{Operation} serialization error (40001), retry {Attempt}/{Max} after {Delay}ms",
                    operationName, retryAttempt, maxRetries, delayMs);
                await Task.Delay(delayMs, cancellationToken);
            }
            catch (PostgresException ex) when (ex.SqlState == "40003")
            {
                // 40003 - Ambiguous result - INDETERMINATE
                // For idempotent operations, treat as success
                logger.LogWarning("{Operation} ambiguous result (40003), treating as success (operations are idempotent)",
                    operationName);

                // Return default - caller should verify if needed
                // For this workload, all operations are idempotent
                return default!;
            }
            catch (PostgresException ex) when (ex.SqlState?.StartsWith("08") == true ||
                                                 ex.SqlState?.StartsWith("57") == true)
            {
                // 08xx, 57xx - Connection/network errors - RETRY
                retryAttempt++;
                if (retryAttempt > maxRetries)
                {
                    logger.LogError(ex, "{Operation} failed after {MaxRetries} connection retries ({SqlState})",
                        operationName, maxRetries, ex.SqlState);
                    throw;
                }

                var delayMs = CalculateBackoffMs(retryAttempt);
                logger.LogWarning("{Operation} connection error ({SqlState}), retry {Attempt}/{Max} after {Delay}ms",
                    operationName, ex.SqlState, retryAttempt, maxRetries, delayMs);
                await Task.Delay(delayMs, cancellationToken);
            }
            catch (PostgresException ex) when (ex.SqlState == "23505")
            {
                // 23505 - Unique violation - IGNORE for idempotent operations
                logger.LogDebug("{Operation} duplicate key ignored (23505)", operationName);
                return default!; // Operation already completed, treat as success
            }
        }

        throw new InvalidOperationException($"{operationName} exceeded retry loop without throwing");
    }

    public static async Task ExecuteWithRetryAsync(
        Func<Task> operation,
        ILogger logger,
        string operationName = "database operation",
        int maxRetries = 10,
        CancellationToken cancellationToken = default)
    {
        await ExecuteWithRetryAsync(async () =>
        {
            await operation();
            return 0; // Dummy return value
        }, logger, operationName, maxRetries, cancellationToken);
    }

    /// <summary>
    /// Calculates exponential backoff delay in milliseconds.
    /// Attempt 1: 100ms, Attempt 2: 200ms, Attempt 3: 400ms, Attempt 4: 800ms, etc.
    /// Capped at 5 seconds to prevent excessive delays.
    /// </summary>
    private static int CalculateBackoffMs(int attempt)
    {
        var baseDelayMs = 100;
        var exponentialDelay = baseDelayMs * (int)Math.Pow(2, attempt - 1);
        var maxDelayMs = 5000; // Cap at 5 seconds
        return Math.Min(exponentialDelay, maxDelayMs);
    }

    /// <summary>
    /// Determines if an exception is retriable based on PostgreSQL error code.
    /// </summary>
    public static bool IsRetriableError(Exception ex)
    {
        if (ex is not PostgresException pgEx)
            return false;

        return pgEx.SqlState switch
        {
            "40001" => true,  // Serialization failure
            "40003" => true,  // Ambiguous result
            "23505" => true,  // Unique violation (idempotent)
            _ when pgEx.SqlState?.StartsWith("08") == true => true,  // Connection errors
            _ when pgEx.SqlState?.StartsWith("57") == true => true,  // Server errors
            _ => false
        };
    }

    /// <summary>
    /// Gets a human-readable description of the error type.
    /// </summary>
    public static string GetErrorDescription(PostgresException ex)
    {
        return ex.SqlState switch
        {
            "40001" => "Serialization failure (concurrent transaction conflict)",
            "40003" => "Ambiguous result (commit status unknown)",
            "23505" => "Unique violation (duplicate key)",
            _ when ex.SqlState?.StartsWith("08") == true => $"Connection error ({ex.SqlState})",
            _ when ex.SqlState?.StartsWith("57") == true => $"Server error ({ex.SqlState})",
            _ => $"Database error ({ex.SqlState})"
        };
    }
}
