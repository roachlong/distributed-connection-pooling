using EventLogs.Analytics.Hubs;
using EventLogs.Analytics.Models;
using EventLogs.Common;
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
    private DateTime? _overallStartTime;

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
        string gatewayStrategy = "multi",
        CancellationToken cancellationToken = default)
    {
        _metricsCallback = onMetricsUpdate;
        _overallStartTime = DateTime.UtcNow;

        List<RequestStatusAggregate> allAggregates;

        if (gatewayStrategy == "multi")
        {
            // Multi-gateway: query each region through its own gateway in parallel
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
            allAggregates = regionalResults.SelectMany(r => r).ToList();
        }
        else
        {
            // Single-gateway: query all regions through one gateway
            lock (_metricsLock)
            {
                _metrics.Clear();
                _metrics[gatewayStrategy] = new PaginationMetrics
                {
                    Region = gatewayStrategy,
                    StartTime = DateTime.UtcNow
                };
            }

            allAggregates = await FetchAllRegionsThroughSingleGatewayAsync(
                gatewayStrategy, pageSize, maxConcurrentTasksPerRegion, cancellationToken);
        }

        // Send final metrics update with overall timing
        await SendMetricsUpdate(DateTime.UtcNow);

        return allAggregates;
    }

    private async Task<List<RequestStatusAggregate>> FetchAllRegionsThroughSingleGatewayAsync(
        string gateway,
        int pageSize,
        int maxConcurrentTasks,
        CancellationToken cancellationToken)
    {
        var connectionString = _configuration.GetConnectionString($"{gateway}_connection")
            ?? throw new InvalidOperationException($"Connection string for {gateway} not found");

        _logger.LogInformation("[{Gateway}] Starting parallel single-gateway keyset pagination for ALL regions with page size {PageSize}",
            gateway, pageSize);

        // PHASE 1: Get all page cursors (fast, minimal data transfer)
        var pageCursors = await DatabaseRetryHelper.ExecuteWithRetryAsync(
            () => GetPageCursorsAllRegionsAsync(gateway, connectionString, pageSize, cancellationToken),
            _logger,
            $"GetPageCursorsAllRegions[{gateway}]",
            maxRetries: 5,
            cancellationToken);

        lock (_metricsLock)
        {
            _metrics[gateway].TotalPages = pageCursors.Count;
        }

        _logger.LogInformation("[{Gateway}] Found {PageCount} pages to fetch in parallel across all regions",
            gateway, pageCursors.Count);

        // PHASE 2: Fetch all pages in parallel using Task.WhenAll
        _logger.LogInformation("[{Gateway}] Creating {TaskCount} parallel tasks with maxConcurrent={MaxConcurrent}",
            gateway, pageCursors.Count, maxConcurrentTasks);

        var semaphore = new SemaphoreSlim(maxConcurrentTasks, maxConcurrentTasks);
        var startTime = DateTime.UtcNow;

        async Task<(List<RequestStatusAggregate> aggregates, int rowCount, Guid? lastRequestId)> FetchWithSemaphore(PageCursor cursor)
        {
            await semaphore.WaitAsync(cancellationToken);
            try
            {
                var taskStart = DateTime.UtcNow;
                _logger.LogDebug("[{Gateway}] Task for page {Page} starting at {Time}",
                    gateway, cursor.PageNumber, taskStart.ToString("HH:mm:ss.fff"));

                var result = await DatabaseRetryHelper.ExecuteWithRetryAsync(
                    () => FetchPageAllRegionsAsync(gateway, connectionString, cursor, pageSize, cancellationToken),
                    _logger,
                    $"FetchPageAllRegions[{gateway}][Page{cursor.PageNumber}]",
                    maxRetries: 5,
                    cancellationToken);

                var taskEnd = DateTime.UtcNow;
                _logger.LogDebug("[{Gateway}] Task for page {Page} completed at {Time} (duration: {Duration}ms)",
                    gateway, cursor.PageNumber, taskEnd.ToString("HH:mm:ss.fff"), (taskEnd - taskStart).TotalMilliseconds);

                // Update metrics immediately as each task completes
                lock (_metricsLock)
                {
                    _metrics[gateway].CompletedPages++;
                    _metrics[gateway].TotalRowsProcessed += result.rowCount;
                }

                // Send real-time metrics update
                await SendMetricsUpdate();

                return result;
            }
            finally
            {
                semaphore.Release();
            }
        }

        var pageTasks = pageCursors.Select(FetchWithSemaphore).ToArray();

        _logger.LogInformation("[{Gateway}] All {Count} tasks created, waiting for completion...", gateway, pageTasks.Length);
        var pageResults = await Task.WhenAll(pageTasks);
        var totalTime = (DateTime.UtcNow - startTime).TotalMilliseconds;

        _logger.LogInformation("[{Gateway}] All parallel tasks completed in {TotalTime}ms", gateway, totalTime);

        // Merge all page results into aggregates (metrics already updated in real-time by tasks)
        var regionalAggregates = new Dictionary<(string requestType, string status, string region), RequestStatusAggregate>();

        foreach (var pageResult in pageResults)
        {
            foreach (var agg in pageResult.aggregates)
            {
                var key = (agg.RequestType, agg.Status, agg.Region);
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

        // Mark region as complete
        long totalRowsProcessed;
        lock (_metricsLock)
        {
            _metrics[gateway].EndTime = DateTime.UtcNow;
            totalRowsProcessed = _metrics[gateway].TotalRowsProcessed;
        }

        _logger.LogInformation("[{Gateway}] Completed parallel single-gateway keyset pagination. Total pages: {Pages}, Total rows: {Rows}, Total aggregates: {Count}",
            gateway, pageCursors.Count, totalRowsProcessed, regionalAggregates.Count);

        return regionalAggregates.Values.ToList();
    }

    private async Task<List<PageCursor>> GetPageCursorsAllRegionsAsync(
        string gateway,
        string connectionString,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var cursors = new List<PageCursor>();

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // Use window function to find page boundaries WITHOUT fetching actual data - across ALL regions
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                t.request_id,
                t.rn,
                ((t.rn - 1) / @pageSize) + 1 as page_number
            FROM (
                SELECT
                    rsh.request_id,
                    row_number() OVER (ORDER BY rsh.request_id) as rn
                FROM request_status_head rsh
            ) t AS OF SYSTEM TIME follower_read_timestamp()
            WHERE (t.rn - 1) % @pageSize = 0
            ORDER BY t.request_id
        ", conn);

        cmd.Parameters.AddWithValue("pageSize", pageSize);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            cursors.Add(new PageCursor
            {
                StartRequestId = reader.GetGuid(0),
                RowOffset = reader.GetInt64(1) - 1,
                PageNumber = reader.GetInt32(2)
            });
        }

        return cursors;
    }

    private async Task<(List<RequestStatusAggregate> aggregates, int rowCount, Guid? lastRequestId)> FetchPageAllRegionsAsync(
        string gateway,
        string connectionString,
        PageCursor cursor,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();
        var aggregates = new List<RequestStatusAggregate>();
        Guid? newLastRequestId = null;
        int rowCount = 0;

        await using var conn = new NpgsqlConnection(connectionString);

        var connOpenStart = Stopwatch.StartNew();
        await conn.OpenAsync(cancellationToken);
        connOpenStart.Stop();

        _logger.LogDebug("[{Gateway}] Page {Page} opened connection in {Ms}ms (Connection ID: {ConnId})",
            gateway, cursor.PageNumber, connOpenStart.ElapsedMilliseconds, conn.ProcessID);

        UpdateConnectionMetrics(gateway, conn);

        // Use keyset pagination with follower reads starting from cursor position - query all regions through this gateway
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                rsh.request_id,
                rt.request_type_code,
                rs.status_code,
                rsh.crdb_region
            FROM request_status_head rsh
            JOIN request_info ri ON rsh.request_id = ri.request_id
            JOIN request_type rt ON ri.request_type_id = rt.request_type_id
            JOIN request_status rs ON rsh.status_id = rs.status_id
            AS OF SYSTEM TIME follower_read_timestamp()
            WHERE rsh.request_id >= @startRequestId
            ORDER BY rsh.request_id
            LIMIT @pageSize
        ", conn);

        cmd.Parameters.AddWithValue("pageSize", pageSize);
        cmd.Parameters.AddWithValue("startRequestId", cursor.StartRequestId);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        // Count occurrences for aggregation
        var pageCounts = new Dictionary<(string requestType, string status, string region), int>();
        while (await reader.ReadAsync(cancellationToken))
        {
            newLastRequestId = reader.GetGuid(0);
            var key = (reader.GetString(1), reader.GetString(2), reader.GetString(3));
            pageCounts[key] = pageCounts.GetValueOrDefault(key, 0) + 1;
            rowCount++;
        }

        // Convert to aggregates
        foreach (var kvp in pageCounts)
        {
            aggregates.Add(new RequestStatusAggregate
            {
                RequestType = kvp.Key.requestType,
                Status = kvp.Key.status,
                Region = kvp.Key.region,
                Count = kvp.Value
            });
        }

        sw.Stop();

        // Update metrics
        lock (_metricsLock)
        {
            var metrics = _metrics[gateway];
            metrics.TotalQueries++;

            // Update average response time
            var totalTime = metrics.AverageResponseTimeMs * (metrics.TotalQueries - 1) + sw.Elapsed.TotalMilliseconds;
            metrics.AverageResponseTimeMs = totalTime / metrics.TotalQueries;
        }

        _logger.LogDebug("[{Gateway}] Page {Page} completed in {Ms}ms, rows: {Rows}",
            gateway, cursor.PageNumber, sw.ElapsedMilliseconds, rowCount);

        return (aggregates, rowCount, newLastRequestId);
    }

    private async Task<List<RequestStatusAggregate>> FetchRegionalDataAsync(
        string region,
        int pageSize,
        int maxConcurrentTasks,
        CancellationToken cancellationToken)
    {
        var connectionString = _configuration.GetConnectionString($"{region}_connection")
            ?? throw new InvalidOperationException($"Connection string for {region} not found");

        _logger.LogInformation("[{Region}] Starting parallel keyset pagination with page size {PageSize}",
            region, pageSize);

        // PHASE 1: Get all page cursors (fast, minimal data transfer)
        var pageCursors = await DatabaseRetryHelper.ExecuteWithRetryAsync(
            () => GetPageCursorsAsync(region, connectionString, pageSize, cancellationToken),
            _logger,
            $"GetPageCursors[{region}]",
            maxRetries: 5,
            cancellationToken);

        lock (_metricsLock)
        {
            _metrics[region].TotalPages = pageCursors.Count;
        }

        _logger.LogInformation("[{Region}] Found {PageCount} pages to fetch in parallel",
            region, pageCursors.Count);

        // PHASE 2: Fetch all pages in parallel using Task.WhenAll
        _logger.LogInformation("[{Region}] Creating {TaskCount} parallel tasks with maxConcurrent={MaxConcurrent}",
            region, pageCursors.Count, maxConcurrentTasks);

        var semaphore = new SemaphoreSlim(maxConcurrentTasks, maxConcurrentTasks);
        var startTime = DateTime.UtcNow;

        async Task<(List<RequestStatusAggregate> aggregates, int rowCount, Guid? lastRequestId)> FetchWithSemaphore(PageCursor cursor)
        {
            await semaphore.WaitAsync(cancellationToken);
            try
            {
                var taskStart = DateTime.UtcNow;
                _logger.LogDebug("[{Region}] Task for page {Page} starting at {Time}",
                    region, cursor.PageNumber, taskStart.ToString("HH:mm:ss.fff"));

                var result = await DatabaseRetryHelper.ExecuteWithRetryAsync(
                    () => FetchPageAsync(region, connectionString, cursor, pageSize, cancellationToken),
                    _logger,
                    $"FetchPage[{region}][Page{cursor.PageNumber}]",
                    maxRetries: 5,
                    cancellationToken);

                var taskEnd = DateTime.UtcNow;
                _logger.LogDebug("[{Region}] Task for page {Page} completed at {Time} (duration: {Duration}ms)",
                    region, cursor.PageNumber, taskEnd.ToString("HH:mm:ss.fff"), (taskEnd - taskStart).TotalMilliseconds);

                // Update metrics immediately as each task completes
                lock (_metricsLock)
                {
                    _metrics[region].CompletedPages++;
                    _metrics[region].TotalRowsProcessed += result.rowCount;
                }

                // Send real-time metrics update
                await SendMetricsUpdate();

                return result;
            }
            finally
            {
                semaphore.Release();
            }
        }

        var pageTasks = pageCursors.Select(FetchWithSemaphore).ToArray();

        _logger.LogInformation("[{Region}] All {Count} tasks created, waiting for completion...", region, pageTasks.Length);
        var pageResults = await Task.WhenAll(pageTasks);
        var totalTime = (DateTime.UtcNow - startTime).TotalMilliseconds;

        _logger.LogInformation("[{Region}] All parallel tasks completed in {TotalTime}ms", region, totalTime);

        // Merge all page results into aggregates (metrics already updated in real-time by tasks)
        var regionalAggregates = new Dictionary<(string requestType, string status), RequestStatusAggregate>();

        foreach (var pageResult in pageResults)
        {
            foreach (var agg in pageResult.aggregates)
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

        // Mark region as complete
        long totalRowsProcessed;
        lock (_metricsLock)
        {
            _metrics[region].EndTime = DateTime.UtcNow;
            totalRowsProcessed = _metrics[region].TotalRowsProcessed;
        }

        _logger.LogInformation("[{Region}] Completed parallel keyset pagination. Total pages: {Pages}, Total rows: {Rows}, Total aggregates: {Count}",
            region, pageCursors.Count, totalRowsProcessed, regionalAggregates.Count);

        return regionalAggregates.Values.ToList();
    }

    private async Task<List<PageCursor>> GetPageCursorsAsync(
        string region,
        string connectionString,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var cursors = new List<PageCursor>();

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // Use window function to find page boundaries WITHOUT fetching actual data
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                t.request_id,
                t.rn,
                ((t.rn - 1) / @pageSize) + 1 as page_number
            FROM (
                SELECT
                    rsh.request_id,
                    row_number() OVER (ORDER BY rsh.request_id) as rn
                FROM request_status_head rsh
                WHERE rsh.crdb_region = @region
            ) t AS OF SYSTEM TIME follower_read_timestamp()
            WHERE (t.rn - 1) % @pageSize = 0
            ORDER BY t.request_id
        ", conn);

        cmd.Parameters.AddWithValue("region", region);
        cmd.Parameters.AddWithValue("pageSize", pageSize);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            cursors.Add(new PageCursor
            {
                StartRequestId = reader.GetGuid(0),
                RowOffset = reader.GetInt64(1) - 1,
                PageNumber = reader.GetInt32(2)
            });
        }

        return cursors;
    }

    private async Task<(List<RequestStatusAggregate> aggregates, int rowCount, Guid? lastRequestId)> FetchPageAsync(
        string region,
        string connectionString,
        PageCursor cursor,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();
        var aggregates = new List<RequestStatusAggregate>();
        Guid? newLastRequestId = null;
        int rowCount = 0;

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        UpdateConnectionMetrics(region, conn);

        // Use keyset pagination with follower reads starting from cursor position
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                rsh.request_id,
                rt.request_type_code,
                rs.status_code
            FROM request_status_head rsh
            JOIN request_info ri ON rsh.request_id = ri.request_id
            JOIN request_type rt ON ri.request_type_id = rt.request_type_id
            JOIN request_status rs ON rsh.status_id = rs.status_id
            AS OF SYSTEM TIME follower_read_timestamp()
            WHERE rsh.crdb_region = @region
              AND rsh.request_id >= @startRequestId
            ORDER BY rsh.request_id
            LIMIT @pageSize
        ", conn);

        cmd.Parameters.AddWithValue("region", region);
        cmd.Parameters.AddWithValue("pageSize", pageSize);
        cmd.Parameters.AddWithValue("startRequestId", cursor.StartRequestId);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        // Count occurrences for aggregation
        var pageCounts = new Dictionary<(string requestType, string status), int>();
        while (await reader.ReadAsync(cancellationToken))
        {
            newLastRequestId = reader.GetGuid(0);
            var key = (reader.GetString(1), reader.GetString(2));
            pageCounts[key] = pageCounts.GetValueOrDefault(key, 0) + 1;
            rowCount++;
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
            metrics.TotalQueries++;

            // Update average response time
            var totalTime = metrics.AverageResponseTimeMs * (metrics.TotalQueries - 1) + sw.Elapsed.TotalMilliseconds;
            metrics.AverageResponseTimeMs = totalTime / metrics.TotalQueries;
        }

        _logger.LogDebug("[{Region}] Page {Page} completed in {Ms}ms, rows: {Rows}",
            region, cursor.PageNumber, sw.ElapsedMilliseconds, rowCount);

        return (aggregates, rowCount, newLastRequestId);
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

    private Task SendMetricsUpdate(DateTime? overallEnd = null)
    {
        GlobalMetrics globalMetrics;
        lock (_metricsLock)
        {
            globalMetrics = new GlobalMetrics
            {
                RegionalMetrics = _metrics.ToDictionary(kvp => kvp.Key, kvp => kvp.Value),
                OverallStartTime = _overallStartTime,
                OverallEndTime = overallEnd
            };
        }

        _metricsCallback?.Invoke(globalMetrics);
        return Task.CompletedTask;
    }

    public async Task<List<RequestDetail>> FetchRequestDetailsAsync(
        string region,
        string requestType,
        string status,
        int limit = 100,
        CancellationToken cancellationToken = default)
    {
        var connectionString = _configuration.GetConnectionString($"{region}_connection")
            ?? throw new InvalidOperationException($"Connection string for {region} not found");

        var details = new List<RequestDetail>();

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new NpgsqlCommand(@"
            SELECT
                ri.request_id,
                rt.request_type_code,
                rs.status_code,
                rsh.crdb_region,
                ri.created_ts,
                rsh.event_ts,
                ri.requested_by,
                ri.primary_account_id
            FROM request_status_head rsh
            JOIN request_info ri ON rsh.request_id = ri.request_id
            JOIN request_type rt ON ri.request_type_id = rt.request_type_id
            JOIN request_status rs ON rsh.status_id = rs.status_id
            AS OF SYSTEM TIME follower_read_timestamp()
            WHERE rsh.crdb_region = @region
              AND rt.request_type_code = @requestType
              AND rs.status_code = @status
            ORDER BY ri.created_ts DESC
            LIMIT @limit
        ", conn);

        cmd.Parameters.AddWithValue("region", region);
        cmd.Parameters.AddWithValue("requestType", requestType);
        cmd.Parameters.AddWithValue("status", status);
        cmd.Parameters.AddWithValue("limit", limit);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            details.Add(new RequestDetail
            {
                RequestId = reader.GetGuid(0),
                RequestType = reader.GetString(1),
                Status = reader.GetString(2),
                Region = reader.GetString(3),
                CreatedAt = reader.GetDateTime(4),
                UpdatedAt = reader.GetDateTime(5),
                RequestedBy = reader.GetString(6),
                AccountId = reader.GetGuid(7)
            });
        }

        return details;
    }

    public async Task<List<Models.EventLogEntry>> FetchEventLogHistoryAsync(
        string region,
        Guid requestId,
        CancellationToken cancellationToken = default)
    {
        var connectionString = _configuration.GetConnectionString($"{region}_connection")
            ?? throw new InvalidOperationException($"Connection string for {region} not found");

        var events = new List<Models.EventLogEntry>();

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new NpgsqlCommand(@"
            SELECT
                rel.seq_num,
                rel.request_id,
                rel.seq_num as sequence_number,
                rat.action_code as event_type,
                rs.status_code,
                rel.event_ts,
                rel.metadata::TEXT,
                NULL as error_message
            FROM request_event_log rel
            JOIN request_action_state_link rasl ON rel.action_state_link_id = rasl.action_state_link_id
            JOIN request_action_type rat ON rasl.action_type_id = rat.action_type_id
            JOIN request_status rs ON rel.status_id = rs.status_id
            AS OF SYSTEM TIME follower_read_timestamp()
            WHERE rel.request_id = @requestId
            ORDER BY rel.seq_num ASC
        ", conn);

        cmd.Parameters.AddWithValue("requestId", requestId);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            events.Add(new Models.EventLogEntry
            {
                LogId = reader.GetInt64(0),
                RequestId = reader.GetGuid(1),
                SequenceNumber = reader.GetInt32(2),
                EventType = reader.GetString(3),
                Status = reader.GetString(4),
                EventTimestamp = reader.GetDateTime(5),
                EventData = reader.IsDBNull(6) ? null : reader.GetString(6),
                ErrorMessage = reader.IsDBNull(7) ? null : reader.GetString(7)
            });
        }

        return events;
    }

    // ==================== TRADE ANALYTICS METHODS ====================

    public async Task<List<TradeAggregate>> FetchTradeAggregatesAsync(
        int pageSize,
        int maxConcurrentTasksPerRegion,
        Action<GlobalMetrics>? onMetricsUpdate = null,
        string gatewayStrategy = "multi",
        CancellationToken cancellationToken = default)
    {
        _metricsCallback = onMetricsUpdate;
        _overallStartTime = DateTime.UtcNow;

        List<TradeAggregate> allAggregates;

        if (gatewayStrategy == "multi")
        {
            var regions = new[] { "us-east", "us-central", "us-west" };

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

            var regionalTasks = regions.Select(region =>
                FetchRegionalTradeDataAsync(region, pageSize, maxConcurrentTasksPerRegion, cancellationToken))
                .ToList();

            var regionalResults = await Task.WhenAll(regionalTasks);
            allAggregates = regionalResults.SelectMany(r => r).ToList();
        }
        else
        {
            lock (_metricsLock)
            {
                _metrics.Clear();
                _metrics[gatewayStrategy] = new PaginationMetrics
                {
                    Region = gatewayStrategy,
                    StartTime = DateTime.UtcNow
                };
            }

            allAggregates = await FetchAllRegionsTradesThroughSingleGatewayAsync(
                gatewayStrategy, pageSize, maxConcurrentTasksPerRegion, cancellationToken);
        }

        await SendMetricsUpdate(DateTime.UtcNow);
        return allAggregates;
    }

    private async Task<List<TradeAggregate>> FetchRegionalTradeDataAsync(
        string region,
        int pageSize,
        int maxConcurrentTasks,
        CancellationToken cancellationToken)
    {
        var connectionString = _configuration.GetConnectionString($"{region}_connection")
            ?? throw new InvalidOperationException($"Connection string for {region} not found");

        _logger.LogInformation("[{Region}] Starting parallel trade keyset pagination with page size {PageSize}",
            region, pageSize);

        // PHASE 1: Get all page cursors (fast, minimal data transfer)
        var pageCursors = await DatabaseRetryHelper.ExecuteWithRetryAsync(
            () => GetTradePageCursorsAsync(region, connectionString, pageSize, cancellationToken),
            _logger,
            $"GetTradePageCursors[{region}]",
            maxRetries: 5,
            cancellationToken);

        lock (_metricsLock)
        {
            _metrics[region].TotalPages = pageCursors.Count;
        }

        _logger.LogInformation("[{Region}] Found {PageCount} trade pages to fetch in parallel",
            region, pageCursors.Count);

        // PHASE 2: Fetch all pages in parallel using Task.WhenAll
        _logger.LogInformation("[{Region}] Creating {TaskCount} parallel tasks with maxConcurrent={MaxConcurrent}",
            region, pageCursors.Count, maxConcurrentTasks);

        var semaphore = new SemaphoreSlim(maxConcurrentTasks, maxConcurrentTasks);
        var startTime = DateTime.UtcNow;

        async Task<(List<TradeAggregate> aggregates, int rowCount, Guid? lastTradeId)> FetchWithSemaphore(TradePageCursor cursor)
        {
            await semaphore.WaitAsync(cancellationToken);
            try
            {
                var taskStart = DateTime.UtcNow;
                _logger.LogDebug("[{Region}] Task for page {Page} starting at {Time}",
                    region, cursor.PageNumber, taskStart.ToString("HH:mm:ss.fff"));

                var result = await DatabaseRetryHelper.ExecuteWithRetryAsync(
                    () => FetchTradePageAsync(region, connectionString, cursor, pageSize, cancellationToken),
                    _logger,
                    $"FetchTradePage[{region}][Page{cursor.PageNumber}]",
                    maxRetries: 5,
                    cancellationToken);

                var taskEnd = DateTime.UtcNow;
                _logger.LogDebug("[{Region}] Task for page {Page} completed at {Time} (duration: {Duration}ms)",
                    region, cursor.PageNumber, taskEnd.ToString("HH:mm:ss.fff"), (taskEnd - taskStart).TotalMilliseconds);

                // Update metrics immediately as each task completes
                lock (_metricsLock)
                {
                    _metrics[region].CompletedPages++;
                    _metrics[region].TotalRowsProcessed += result.rowCount;
                }

                // Send real-time metrics update
                await SendMetricsUpdate();

                return result;
            }
            finally
            {
                semaphore.Release();
            }
        }

        var pageTasks = pageCursors.Select(FetchWithSemaphore).ToArray();

        _logger.LogInformation("[{Region}] All {Count} tasks created, waiting for completion...", region, pageTasks.Length);
        var pageResults = await Task.WhenAll(pageTasks);
        var totalTime = (DateTime.UtcNow - startTime).TotalMilliseconds;

        _logger.LogInformation("[{Region}] All parallel tasks completed in {TotalTime}ms", region, totalTime);

        // Merge all page results into aggregates (metrics already updated in real-time by tasks)
        var regionalAggregates = new Dictionary<(string side, string status, string symbol, string region), TradeAggregate>();

        foreach (var pageResult in pageResults)
        {
            foreach (var agg in pageResult.aggregates)
            {
                var key = (agg.Side, agg.Status, agg.Symbol, agg.Region);
                if (regionalAggregates.ContainsKey(key))
                {
                    regionalAggregates[key].Count += agg.Count;
                    regionalAggregates[key].TotalQuantity += agg.TotalQuantity;
                }
                else
                {
                    regionalAggregates[key] = agg;
                }
            }
        }

        // Recalculate averages
        foreach (var agg in regionalAggregates.Values)
        {
            if (agg.Count > 0 && agg.TotalQuantity > 0)
            {
                agg.AveragePrice = agg.TotalQuantity / agg.Count;
            }
        }

        long totalRowsProcessed;
        lock (_metricsLock)
        {
            _metrics[region].EndTime = DateTime.UtcNow;
            totalRowsProcessed = _metrics[region].TotalRowsProcessed;
        }

        _logger.LogInformation("[{Region}] Completed parallel trade keyset pagination. Total pages: {Pages}, Total rows: {Rows}, Total aggregates: {Count}",
            region, pageCursors.Count, totalRowsProcessed, regionalAggregates.Count);

        return regionalAggregates.Values.ToList();
    }

    private async Task<List<TradePageCursor>> GetTradePageCursorsAsync(
        string region,
        string connectionString,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var cursors = new List<TradePageCursor>();

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // Use window function to find page boundaries WITHOUT fetching actual data
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                t.trade_id,
                t.rn,
                ((t.rn - 1) / @pageSize) + 1 as page_number
            FROM (
                SELECT
                    ti.trade_id,
                    row_number() OVER (ORDER BY ti.trade_id) as rn
                FROM trade_info ti
                WHERE ti.crdb_region = @region
            ) t AS OF SYSTEM TIME follower_read_timestamp()
            WHERE (t.rn - 1) % @pageSize = 0
            ORDER BY t.trade_id
        ", conn);

        cmd.Parameters.AddWithValue("region", region);
        cmd.Parameters.AddWithValue("pageSize", pageSize);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            cursors.Add(new TradePageCursor
            {
                StartTradeId = reader.GetGuid(0),
                RowOffset = reader.GetInt64(1) - 1,
                PageNumber = reader.GetInt32(2)
            });
        }

        return cursors;
    }

    private async Task<(List<TradeAggregate> aggregates, int rowCount, Guid? lastTradeId)> FetchTradePageAsync(
        string region,
        string connectionString,
        TradePageCursor cursor,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();
        var aggregates = new List<TradeAggregate>();
        Guid? newLastTradeId = null;
        int rowCount = 0;

        await using var conn = new NpgsqlConnection(connectionString);

        var connOpenStart = Stopwatch.StartNew();
        await conn.OpenAsync(cancellationToken);
        connOpenStart.Stop();

        _logger.LogDebug("[{Region}] Page {Page} opened connection in {Ms}ms (Connection ID: {ConnId})",
            region, cursor.PageNumber, connOpenStart.ElapsedMilliseconds, conn.ProcessID);

        UpdateConnectionMetrics(region, conn);

        // Use keyset pagination with follower reads starting from cursor position
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                ti.trade_id,
                ti.side,
                rs.status_code,
                ti.symbol,
                ti.crdb_region,
                ti.quantity,
                ti.price
            FROM trade_info ti
            JOIN request_status rs ON ti.status_id = rs.status_id
            AS OF SYSTEM TIME follower_read_timestamp()
            WHERE ti.crdb_region = @region
              AND ti.trade_id >= @startTradeId
            ORDER BY ti.trade_id
            LIMIT @pageSize
        ", conn);

        cmd.Parameters.AddWithValue("region", region);
        cmd.Parameters.AddWithValue("pageSize", pageSize);
        cmd.Parameters.AddWithValue("startTradeId", cursor.StartTradeId);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        var pageCounts = new Dictionary<(string side, string status, string symbol, string region), (int count, decimal totalQty, decimal totalPrice, int priceCount)>();
        while (await reader.ReadAsync(cancellationToken))
        {
            newLastTradeId = reader.GetGuid(0);
            var key = (reader.GetString(1), reader.GetString(2), reader.GetString(3), reader.GetString(4));
            var quantity = reader.GetDecimal(5);
            var price = reader.IsDBNull(6) ? 0m : reader.GetDecimal(6);

            if (pageCounts.ContainsKey(key))
            {
                var current = pageCounts[key];
                pageCounts[key] = (current.count + 1, current.totalQty + quantity, current.totalPrice + (price > 0 ? price : 0), current.priceCount + (price > 0 ? 1 : 0));
            }
            else
            {
                pageCounts[key] = (1, quantity, price > 0 ? price : 0, price > 0 ? 1 : 0);
            }
            rowCount++;
        }

        foreach (var kvp in pageCounts)
        {
            aggregates.Add(new TradeAggregate
            {
                Side = kvp.Key.side,
                Status = kvp.Key.status,
                Symbol = kvp.Key.symbol,
                Region = kvp.Key.region,
                Count = kvp.Value.count,
                TotalQuantity = kvp.Value.totalQty,
                AveragePrice = kvp.Value.priceCount > 0 ? kvp.Value.totalPrice / kvp.Value.priceCount : 0
            });
        }

        sw.Stop();

        lock (_metricsLock)
        {
            var metrics = _metrics[region];
            metrics.TotalQueries++;

            var totalTime = metrics.AverageResponseTimeMs * (metrics.TotalQueries - 1) + sw.Elapsed.TotalMilliseconds;
            metrics.AverageResponseTimeMs = totalTime / metrics.TotalQueries;
        }

        _logger.LogDebug("[{Region}] Trade page {Page} completed in {Ms}ms, rows: {Rows}",
            region, cursor.PageNumber, sw.ElapsedMilliseconds, rowCount);

        return (aggregates, rowCount, newLastTradeId);
    }

    private async Task<List<TradeAggregate>> FetchAllRegionsTradesThroughSingleGatewayAsync(
        string gateway,
        int pageSize,
        int maxConcurrentTasks,
        CancellationToken cancellationToken)
    {
        var connectionString = _configuration.GetConnectionString($"{gateway}_connection")
            ?? throw new InvalidOperationException($"Connection string for {gateway} not found");

        _logger.LogInformation("[{Gateway}] Starting parallel single-gateway trade keyset pagination for ALL regions", gateway);

        // PHASE 1: Get all page cursors (fast, minimal data transfer)
        var pageCursors = await DatabaseRetryHelper.ExecuteWithRetryAsync(
            () => GetTradePageCursorsAllRegionsAsync(gateway, connectionString, pageSize, cancellationToken),
            _logger,
            $"GetTradePageCursorsAllRegions[{gateway}]",
            maxRetries: 5,
            cancellationToken);

        lock (_metricsLock)
        {
            _metrics[gateway].TotalPages = pageCursors.Count;
        }

        _logger.LogInformation("[{Gateway}] Found {PageCount} trade pages to fetch in parallel across all regions",
            gateway, pageCursors.Count);

        // PHASE 2: Fetch all pages in parallel using Task.WhenAll
        _logger.LogInformation("[{Gateway}] Creating {TaskCount} parallel tasks with maxConcurrent={MaxConcurrent}",
            gateway, pageCursors.Count, maxConcurrentTasks);

        var semaphore = new SemaphoreSlim(maxConcurrentTasks, maxConcurrentTasks);
        var startTime = DateTime.UtcNow;

        async Task<(List<TradeAggregate> aggregates, int rowCount, Guid? lastTradeId)> FetchWithSemaphore(TradePageCursor cursor)
        {
            await semaphore.WaitAsync(cancellationToken);
            try
            {
                var taskStart = DateTime.UtcNow;
                _logger.LogDebug("[{Gateway}] Task for page {Page} starting at {Time}",
                    gateway, cursor.PageNumber, taskStart.ToString("HH:mm:ss.fff"));

                var result = await DatabaseRetryHelper.ExecuteWithRetryAsync(
                    () => FetchTradePageAllRegionsAsync(gateway, connectionString, cursor, pageSize, cancellationToken),
                    _logger,
                    $"FetchTradePageAllRegions[{gateway}][Page{cursor.PageNumber}]",
                    maxRetries: 5,
                    cancellationToken);

                var taskEnd = DateTime.UtcNow;
                _logger.LogDebug("[{Gateway}] Task for page {Page} completed at {Time} (duration: {Duration}ms)",
                    gateway, cursor.PageNumber, taskEnd.ToString("HH:mm:ss.fff"), (taskEnd - taskStart).TotalMilliseconds);

                // Update metrics immediately as each task completes
                lock (_metricsLock)
                {
                    _metrics[gateway].CompletedPages++;
                    _metrics[gateway].TotalRowsProcessed += result.rowCount;
                }

                // Send real-time metrics update
                await SendMetricsUpdate();

                return result;
            }
            finally
            {
                semaphore.Release();
            }
        }

        var pageTasks = pageCursors.Select(FetchWithSemaphore).ToArray();

        _logger.LogInformation("[{Gateway}] All {Count} tasks created, waiting for completion...", gateway, pageTasks.Length);
        var pageResults = await Task.WhenAll(pageTasks);
        var totalTime = (DateTime.UtcNow - startTime).TotalMilliseconds;

        _logger.LogInformation("[{Gateway}] All parallel tasks completed in {TotalTime}ms", gateway, totalTime);

        // Merge all page results into aggregates (metrics already updated in real-time by tasks)
        var aggregates = new Dictionary<(string side, string status, string symbol, string region), TradeAggregate>();

        foreach (var pageResult in pageResults)
        {
            foreach (var agg in pageResult.aggregates)
            {
                var key = (agg.Side, agg.Status, agg.Symbol, agg.Region);
                if (aggregates.ContainsKey(key))
                {
                    aggregates[key].Count += agg.Count;
                    aggregates[key].TotalQuantity += agg.TotalQuantity;
                }
                else
                {
                    aggregates[key] = agg;
                }
            }
        }

        long totalRowsProcessed;
        lock (_metricsLock)
        {
            _metrics[gateway].EndTime = DateTime.UtcNow;
            totalRowsProcessed = _metrics[gateway].TotalRowsProcessed;
        }

        _logger.LogInformation("[{Gateway}] Completed parallel single-gateway trade keyset pagination. Total pages: {Pages}, Total rows: {Rows}, Total aggregates: {Count}",
            gateway, pageCursors.Count, totalRowsProcessed, aggregates.Count);

        return aggregates.Values.ToList();
    }

    private async Task<List<TradePageCursor>> GetTradePageCursorsAllRegionsAsync(
        string gateway,
        string connectionString,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var cursors = new List<TradePageCursor>();

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // Use window function to find page boundaries WITHOUT fetching actual data - across ALL regions
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                t.trade_id,
                t.rn,
                ((t.rn - 1) / @pageSize) + 1 as page_number
            FROM (
                SELECT
                    ti.trade_id,
                    row_number() OVER (ORDER BY ti.trade_id) as rn
                FROM trade_info ti
            ) t AS OF SYSTEM TIME follower_read_timestamp()
            WHERE (t.rn - 1) % @pageSize = 0
            ORDER BY t.trade_id
        ", conn);

        cmd.Parameters.AddWithValue("pageSize", pageSize);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            cursors.Add(new TradePageCursor
            {
                StartTradeId = reader.GetGuid(0),
                RowOffset = reader.GetInt64(1) - 1,
                PageNumber = reader.GetInt32(2)
            });
        }

        return cursors;
    }

    private async Task<(List<TradeAggregate> aggregates, int rowCount, Guid? lastTradeId)> FetchTradePageAllRegionsAsync(
        string gateway,
        string connectionString,
        TradePageCursor cursor,
        int pageSize,
        CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();
        var aggregates = new List<TradeAggregate>();
        Guid? newLastTradeId = null;
        int rowCount = 0;

        await using var conn = new NpgsqlConnection(connectionString);

        var connOpenStart = Stopwatch.StartNew();
        await conn.OpenAsync(cancellationToken);
        connOpenStart.Stop();

        _logger.LogDebug("[{Gateway}] Page {Page} opened connection in {Ms}ms (Connection ID: {ConnId})",
            gateway, cursor.PageNumber, connOpenStart.ElapsedMilliseconds, conn.ProcessID);

        UpdateConnectionMetrics(gateway, conn);

        // Use keyset pagination with follower reads starting from cursor position - query all regions through this gateway
        await using var cmd = new NpgsqlCommand(@"
            SELECT
                ti.trade_id,
                ti.side,
                rs.status_code,
                ti.symbol,
                ti.crdb_region,
                ti.quantity,
                ti.price
            FROM trade_info ti
            JOIN request_status rs ON ti.status_id = rs.status_id
            AS OF SYSTEM TIME follower_read_timestamp()
            WHERE ti.trade_id >= @startTradeId
            ORDER BY ti.trade_id
            LIMIT @pageSize
        ", conn);

        cmd.Parameters.AddWithValue("pageSize", pageSize);
        cmd.Parameters.AddWithValue("startTradeId", cursor.StartTradeId);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        var pageCounts = new Dictionary<(string side, string status, string symbol, string region), (int count, decimal totalQty, decimal totalPrice, int priceCount)>();
        while (await reader.ReadAsync(cancellationToken))
        {
            newLastTradeId = reader.GetGuid(0);
            var key = (reader.GetString(1), reader.GetString(2), reader.GetString(3), reader.GetString(4));
            var quantity = reader.GetDecimal(5);
            var price = reader.IsDBNull(6) ? 0m : reader.GetDecimal(6);

            if (pageCounts.ContainsKey(key))
            {
                var current = pageCounts[key];
                pageCounts[key] = (current.count + 1, current.totalQty + quantity, current.totalPrice + (price > 0 ? price : 0), current.priceCount + (price > 0 ? 1 : 0));
            }
            else
            {
                pageCounts[key] = (1, quantity, price > 0 ? price : 0, price > 0 ? 1 : 0);
            }
            rowCount++;
        }

        foreach (var kvp in pageCounts)
        {
            aggregates.Add(new TradeAggregate
            {
                Side = kvp.Key.side,
                Status = kvp.Key.status,
                Symbol = kvp.Key.symbol,
                Region = kvp.Key.region,
                Count = kvp.Value.count,
                TotalQuantity = kvp.Value.totalQty,
                AveragePrice = kvp.Value.priceCount > 0 ? kvp.Value.totalPrice / kvp.Value.priceCount : 0
            });
        }

        sw.Stop();

        lock (_metricsLock)
        {
            var metrics = _metrics[gateway];
            metrics.TotalQueries++;

            var totalTime = metrics.AverageResponseTimeMs * (metrics.TotalQueries - 1) + sw.Elapsed.TotalMilliseconds;
            metrics.AverageResponseTimeMs = totalTime / metrics.TotalQueries;
        }

        _logger.LogDebug("[{Gateway}] Trade page {Page} completed in {Ms}ms, rows: {Rows}",
            gateway, cursor.PageNumber, sw.ElapsedMilliseconds, rowCount);

        return (aggregates, rowCount, newLastTradeId);
    }

    public async Task<List<TradeDetail>> FetchTradeDetailsAsync(
        string region,
        string side,
        string status,
        string symbol,
        int limit = 100,
        CancellationToken cancellationToken = default)
    {
        var connectionString = _configuration.GetConnectionString($"{region}_connection")
            ?? throw new InvalidOperationException($"Connection string for {region} not found");

        var details = new List<TradeDetail>();

        await using var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new NpgsqlCommand(@"
            SELECT
                ti.trade_id,
                ti.request_id,
                ti.account_id,
                ti.symbol,
                ti.side,
                ti.quantity,
                ti.price,
                ti.currency,
                rs.status_code,
                ti.crdb_region,
                ti.created_ts
            FROM trade_info ti
            JOIN request_status rs ON ti.status_id = rs.status_id
            AS OF SYSTEM TIME follower_read_timestamp()
            WHERE ti.crdb_region = @region
              AND ti.side = @side
              AND rs.status_code = @status
              AND ti.symbol = @symbol
            ORDER BY ti.created_ts DESC
            LIMIT @limit
        ", conn);

        cmd.Parameters.AddWithValue("region", region);
        cmd.Parameters.AddWithValue("side", side);
        cmd.Parameters.AddWithValue("status", status);
        cmd.Parameters.AddWithValue("symbol", symbol);
        cmd.Parameters.AddWithValue("limit", limit);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            details.Add(new TradeDetail
            {
                TradeId = reader.GetGuid(0),
                RequestId = reader.GetGuid(1),
                AccountId = reader.GetGuid(2),
                Symbol = reader.GetString(3),
                Side = reader.GetString(4),
                Quantity = reader.GetDecimal(5),
                Price = reader.IsDBNull(6) ? null : reader.GetDecimal(6),
                Currency = reader.IsDBNull(7) ? null : reader.GetString(7),
                Status = reader.GetString(8),
                Region = reader.GetString(9),
                CreatedAt = reader.GetDateTime(10)
            });
        }

        return details;
    }
}
