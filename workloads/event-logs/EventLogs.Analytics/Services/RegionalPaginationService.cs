using EventLogs.Analytics.Hubs;
using EventLogs.Analytics.Models;
using EventLogs.Data;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using Npgsql;
using System.Diagnostics;

namespace EventLogs.Analytics.Services;

public class RegionalPaginationService
{
    private readonly IConfiguration _configuration;
    private readonly ILogger<RegionalPaginationService> _logger;
    private readonly Dictionary<string, PaginationMetrics> _metrics = new();
    private readonly object _metricsLock = new();
    private Action<GlobalMetrics>? _metricsCallback;

    public RegionalPaginationService(
        IConfiguration configuration,
        ILogger<RegionalPaginationService> logger)
    {
        _configuration = configuration;
        _logger = logger;
    }

    public async Task<List<RequestStatusAggregate>> FetchRequestStatusAggregatesAsync(
        int pageSize,
        int maxConcurrentTasksPerRegion,
        Action<GlobalMetrics>? onMetricsUpdate = null,
        CancellationToken cancellationToken = default)
    {
        _metricsCallback = onMetricsUpdate;
        var regions = new[] { "us-east", "us-central", "us-west" };

        // Initialize metrics for each region
        lock (_metricsLock)
        {
            _metrics.Clear();
            foreach (var region in regions)
            {
                _metrics[region] = new PaginationMetrics
                {
                    Region = region,
                    StartTime = DateTime.UtcNow
                };
            }
        }

        // Start regional tasks in parallel
        var regionalTasks = regions.Select(region =>
            FetchRegionalDataAsync(region, pageSize, maxConcurrentTasksPerRegion, cancellationToken))
            .ToList();

        // Wait for all regional tasks to complete
        var regionalResults = await Task.WhenAll(regionalTasks);

        // Merge results from all regions
        var allAggregates = regionalResults.SelectMany(r => r).ToList();

        // Send final metrics update
        await SendMetricsUpdate();

        return allAggregates;
    }

    private async Task<List<RequestStatusAggregate>> FetchRegionalDataAsync(
        string region,
        int pageSize,
        int maxConcurrentTasks,
        CancellationToken cancellationToken)
    {
        var connectionString = _configuration.GetConnectionString($"{region}_connection")
            ?? throw new InvalidOperationException($"Connection string for {region} not found");

        _logger.LogInformation("[{Region}] Starting pagination with page size {PageSize}, max concurrent tasks: {MaxTasks}",
            region, pageSize, maxConcurrentTasks);

        // First, get total count to calculate pages
        long totalCount;
        await using (var countConn = new NpgsqlConnection(connectionString))
        {
            await countConn.OpenAsync(cancellationToken);
            await using var cmd = new NpgsqlCommand(
                "SELECT COUNT(*) FROM request_status_head WHERE crdb_region = @region",
                countConn);
            cmd.Parameters.AddWithValue("region", region);
            totalCount = (long)(await cmd.ExecuteScalarAsync(cancellationToken) ?? 0L);
        }

        var totalPages = (int)Math.Ceiling(totalCount / (double)pageSize);

        lock (_metricsLock)
        {
            _metrics[region].TotalPages = totalPages;
        }

        _logger.LogInformation("[{Region}] Total rows: {TotalRows}, Total pages: {TotalPages}",
            region, totalCount, totalPages);

        // If no data, return empty
        if (totalPages == 0)
        {
            lock (_metricsLock)
            {
                _metrics[region].EndTime = DateTime.UtcNow;
            }
            await SendMetricsUpdate();
            return new List<RequestStatusAggregate>();
        }

        // Create a semaphore to limit concurrent tasks
        using var semaphore = new SemaphoreSlim(maxConcurrentTasks);
        var pageTasks = new List<Task<List<RequestStatusAggregate>>>();

        // Queue up all page tasks
        for (int page = 0; page < totalPages; page++)
        {
            var pageNumber = page;
            pageTasks.Add(FetchPageAsync(region, connectionString, pageNumber, pageSize, totalPages, semaphore, cancellationToken));
        }

        // Wait for all pages to complete
        var pageResults = await Task.WhenAll(pageTasks);

        // Mark region as complete
        lock (_metricsLock)
        {
            _metrics[region].EndTime = DateTime.UtcNow;
        }

        // Aggregate results from all pages
        var regionalAggregates = new Dictionary<(string requestType, string status), RequestStatusAggregate>();

        foreach (var pageResult in pageResults)
        {
            foreach (var agg in pageResult)
            {
                var key = (agg.RequestType, agg.Status);
                if (regionalAggregates.ContainsKey(key))
                {
                    regionalAggregates[key].Count += agg.Count;
                }
                else
                {
                    regionalAggregates[key] = agg;
                }
            }
        }

        _logger.LogInformation("[{Region}] Completed pagination. Total aggregates: {Count}",
            region, regionalAggregates.Count);

        return regionalAggregates.Values.ToList();
    }

    private async Task<List<RequestStatusAggregate>> FetchPageAsync(
        string region,
        string connectionString,
        int pageNumber,
        int pageSize,
        int totalPages,
        SemaphoreSlim semaphore,
        CancellationToken cancellationToken)
    {
        await semaphore.WaitAsync(cancellationToken);

        try
        {
            var sw = Stopwatch.StartNew();
            var aggregates = new List<RequestStatusAggregate>();

            await using var conn = new NpgsqlConnection(connectionString);
            await conn.OpenAsync(cancellationToken);

            // Track active connections (approximate using pool stats)
            UpdateConnectionMetrics(region, conn);

            var offset = pageNumber * pageSize;

            // Query raw request_status_head rows and join with request_info to get type
            // We paginate the raw rows to test connection pooling and query performance
            await using var cmd = new NpgsqlCommand(@"
                SELECT
                    rt.request_type_code,
                    rs.status_code
                FROM request_status_head rsh
                JOIN request_info ri ON rsh.request_id = ri.request_id
                JOIN request_type rt ON ri.request_type_id = rt.request_type_id
                JOIN request_status rs ON rsh.status_id = rs.status_id
                WHERE rsh.crdb_region = @region
                ORDER BY rsh.request_id
                LIMIT @pageSize OFFSET @offset
            ", conn);

            cmd.Parameters.AddWithValue("region", region);
            cmd.Parameters.AddWithValue("pageSize", pageSize);
            cmd.Parameters.AddWithValue("offset", offset);

            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

            // Count occurrences for aggregation
            var pageCounts = new Dictionary<(string requestType, string status), int>();
            while (await reader.ReadAsync(cancellationToken))
            {
                var key = (reader.GetString(0), reader.GetString(1));
                pageCounts[key] = pageCounts.GetValueOrDefault(key, 0) + 1;
            }

            // Convert to aggregates
            foreach (var kvp in pageCounts)
            {
                aggregates.Add(new RequestStatusAggregate
                {
                    RequestType = kvp.Key.requestType,
                    Status = kvp.Key.status,
                    Count = kvp.Value,
                    Region = region
                });
            }

            sw.Stop();

            // Update metrics
            lock (_metricsLock)
            {
                var metrics = _metrics[region];
                metrics.CompletedPages++;
                metrics.TotalQueries++;
                metrics.TotalRowsProcessed += aggregates.Count;

                // Update average response time
                var totalTime = metrics.AverageResponseTimeMs * (metrics.TotalQueries - 1) + sw.Elapsed.TotalMilliseconds;
                metrics.AverageResponseTimeMs = totalTime / metrics.TotalQueries;
            }

            // Send progress update every 10 pages or on last page
            if (pageNumber % 10 == 0 || pageNumber == totalPages - 1)
            {
                await SendMetricsUpdate();
            }

            _logger.LogDebug("[{Region}] Page {Page}/{Total} completed in {Ms}ms, rows: {Rows}",
                region, pageNumber + 1, totalPages, sw.ElapsedMilliseconds, aggregates.Count);

            return aggregates;
        }
        finally
        {
            semaphore.Release();
        }
    }

    private void UpdateConnectionMetrics(string region, NpgsqlConnection conn)
    {
        try
        {
            lock (_metricsLock)
            {
                // Note: Npgsql doesn't expose detailed pool stats easily via the connection object
                // This is a simplified tracking - we just track that a connection is active
                _metrics[region].ActiveConnections = 1; // Simplified - actual count requires Npgsql.PoolManager
                if (_metrics[region].PeakConnections < _metrics[region].ActiveConnections)
                {
                    _metrics[region].PeakConnections = _metrics[region].ActiveConnections;
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[{Region}] Failed to update connection metrics", region);
        }
    }

    private Task SendMetricsUpdate()
    {
        GlobalMetrics globalMetrics;
        lock (_metricsLock)
        {
            globalMetrics = new GlobalMetrics
            {
                RegionalMetrics = _metrics.ToDictionary(kvp => kvp.Key, kvp => kvp.Value)
            };
        }

        _metricsCallback?.Invoke(globalMetrics);
        return Task.CompletedTask;
    }
}
