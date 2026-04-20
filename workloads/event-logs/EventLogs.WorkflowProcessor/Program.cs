using Confluent.Kafka;
using EventLogs.Common;
using EventLogs.Data;
using EventLogs.Domain.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Npgsql;
using System.Diagnostics;
using System.Text.Json;

var configuration = new ConfigurationBuilder()
    .SetBasePath(Directory.GetCurrentDirectory())
    .AddJsonFile("appsettings.json", optional: false)
    .AddEnvironmentVariables()
    .Build();

var connectionString = configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("DefaultConnection not found");

var region = configuration.GetValue<string>("Region")
    ?? throw new InvalidOperationException("Region not configured");

var kafkaBootstrap = configuration.GetValue<string>("KafkaBootstrap")
    ?? throw new InvalidOperationException("KafkaBootstrap not configured");

var topic = $"request-events.{region}";
var partitionCount = configuration.GetValue<int>("PartitionCount", 24);
var batchSize = configuration.GetValue<int>("BatchSize", 128);
var batchWindowMs = configuration.GetValue<int>("BatchWindowMs", 1000);
var maxRetries = configuration.GetValue<int>("MaxRetries", 5);
var processingDelayMs = configuration.GetValue<int>("ProcessingDelayMs", 100);

using var loggerFactory = LoggerFactory.Create(builder => builder.AddConsole());
var logger = loggerFactory.CreateLogger<Program>();

logger.LogInformation("=== Workflow Processor [{Region}] ===", region);
logger.LogInformation("Kafka: {Bootstrap}, Topic: {Topic}", kafkaBootstrap, topic);
logger.LogInformation("Partitions: {Count}, Batch Size: {BatchSize}, Window: {WindowMs}ms",
    partitionCount, batchSize, batchWindowMs);

// Load workflow state machine from database
Dictionary<int, List<WorkflowTransition>> workflowTransitions;
var optionsBuilder = new DbContextOptionsBuilder<EventLogsContext>();
optionsBuilder.UseNpgsql(connectionString);

using (var setupContext = new EventLogsContext(optionsBuilder.Options))
{
    // Load request_action_state_link data grouped by request_type_id
    workflowTransitions = await setupContext.RequestActionStateLink
        .OrderBy(rasl => rasl.RequestTypeId)
        .ThenBy(rasl => rasl.SortOrder)
        .ToListAsync()
        .ContinueWith(task =>
        {
            return task.Result
                .GroupBy(rasl => rasl.RequestTypeId)
                .ToDictionary(
                    g => g.Key,
                    g => g.Select(rasl => new WorkflowTransition
                    {
                        ActionStateLinkId = rasl.ActionStateLinkId,
                        ActionTypeId = rasl.ActionTypeId,
                        StateId = rasl.StateId,
                        SortOrder = rasl.SortOrder,
                        IsInitial = rasl.IsInitial,
                        IsTerminal = rasl.IsTerminal
                    }).ToList()
                );
        });

    logger.LogInformation("Loaded workflow transitions for {Count} request types", workflowTransitions.Count);
}

// Setup cancellation
using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    logger.LogInformation("Shutdown requested...");
    cts.Cancel();
};

// Start one consumer task per partition
var tasks = new List<Task>();
for (int partition = 0; partition < partitionCount; partition++)
{
    var partitionId = partition;
    tasks.Add(Task.Run(async () =>
        await ProcessPartition(partitionId, topic, kafkaBootstrap, connectionString,
            workflowTransitions, batchSize, batchWindowMs, maxRetries, processingDelayMs,
            logger, cts.Token),
        cts.Token));
}

logger.LogInformation("Started {Count} partition consumers", tasks.Count);

try
{
    await Task.WhenAll(tasks);
}
catch (OperationCanceledException)
{
    logger.LogInformation("Workflow processor shutdown complete");
}

return 0;

// =============================================================================
// Process events from a single Kafka partition
// =============================================================================
static async Task ProcessPartition(
    int partition,
    string topic,
    string kafkaBootstrap,
    string connectionString,
    Dictionary<int, List<WorkflowTransition>> workflowTransitions,
    int batchSize,
    int batchWindowMs,
    int maxRetries,
    int processingDelayMs,
    ILogger logger,
    CancellationToken cancellationToken)
{
    var consumerConfig = new ConsumerConfig
    {
        BootstrapServers = kafkaBootstrap,
        GroupId = $"workflow-processor-{topic}-p{partition}-v3",
        AutoOffsetReset = AutoOffsetReset.Earliest,
        EnableAutoCommit = true,
        EnableAutoOffsetStore = false
    };

    using var consumer = new ConsumerBuilder<string, string>(consumerConfig).Build();
    await Task.Delay(1000, cancellationToken); // Wait 1 second before assigning

    consumer.Assign(new TopicPartition(topic, partition));
    logger.LogInformation("[P{Partition}] Assigned to {Topic}", partition, topic);

    var batch = new List<RequestEvent>();
    var consecutiveFailures = 0;
    var processedCount = 0L;
    var stopwatch = Stopwatch.StartNew();
    ConsumeResult<string, string>? lastConsumeResult = null;

    try
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            // Don't block forever, we want to process messages within our batch window
            var consumeResult = consumer.Consume(batchWindowMs);

            // if no message consumed then continue
            if (!cancellationToken.IsCancellationRequested && consumeResult != null && consumeResult.Message.Value != null)
            {
                // Parse CDC event - CRDB changefeeds send the row data directly, not wrapped in "after"
                CDCEventData? eventData = null;
                try
                {
                    eventData = JsonSerializer.Deserialize<CDCEventData>(consumeResult.Message.Value);
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "[P{Partition}] Failed to deserialize message: {Message}",
                        partition, consumeResult.Message.Value.Length > 500 ? consumeResult.Message.Value.Substring(0, 500) : consumeResult.Message.Value);
                    continue;
                }

                // if a valid message was received then process it
                // Skip events where action_state_link_id is null (these are trigger updates to request_status_head)
                if (eventData != null && eventData.action_state_link_id.HasValue && eventData.status_id.HasValue &&
                    eventData.event_ts.HasValue && !string.IsNullOrEmpty(eventData.idempotency_key))
                {
                    // if the event is valid add it to our internal buffer
                    batch.Add(new RequestEvent
                    {
                        RequestId = eventData.request_id,
                        SeqNum = eventData.seq_num,
                        ActionStateLinkId = eventData.action_state_link_id.Value,
                        StatusId = eventData.status_id.Value,
                        EventTs = eventData.event_ts.Value,
                        Actor = eventData.actor,
                        Metadata = eventData.metadata?.GetRawText(),
                        IdempotencyKey = eventData.idempotency_key,
                        Offset = consumeResult.Offset
                    });

                    lastConsumeResult = consumeResult;

                    // flush the events to the database if batch size or time limit exceeded
                    if (batch.Count >= batchSize || stopwatch.ElapsedMilliseconds >= batchWindowMs)
                    {
                        await ProcessBatch(batch, connectionString, workflowTransitions, processingDelayMs, logger, partition, cancellationToken);

                        // commit the last message we received before flushing the internal buffer
                        consumer.StoreOffset(consumeResult);

                        // database transaction succeeded, reset state for next batch
                        processedCount += batch.Count;
                        consecutiveFailures = 0;
                        batch.Clear();
                        stopwatch.Restart();

                        if (processedCount % 100 == 0)
                        {
                            logger.LogInformation("[P{Partition}] Processed {Count} events total", partition, processedCount);
                        }
                    }
                }
                // Events with null fields are skipped silently (these are trigger updates)
            }

            // if we've stopped consuming due to the process being cancelled
            // and/or we've also waited past our batch window time limit
            // make sure we flush our internal buffer of acknowledged event messages
            if (batch.Count > 0 && lastConsumeResult != null && (
                cancellationToken.IsCancellationRequested || stopwatch.ElapsedMilliseconds >= batchWindowMs
            ))
            {
                await ProcessBatch(batch, connectionString, workflowTransitions, processingDelayMs, logger, partition, cancellationToken);

                // commit the last message we received before flushing the internal buffer
                consumer.StoreOffset(lastConsumeResult);

                // database transaction succeeded, reset state for next batch
                processedCount += batch.Count;
                consecutiveFailures = 0;
                batch.Clear();
                stopwatch.Restart();

                if (processedCount % 100 == 0)
                {
                    logger.LogInformation("[P{Partition}] Processed {Count} events total", partition, processedCount);
                }
            }
        }
    }
    catch (OperationCanceledException)
    {
        logger.LogInformation("[P{Partition}] Cancellation request received", partition);
    }
    catch (ConsumeException e)
    {
        logger.LogError("[P{Partition}] ERROR consuming message: {Reason}", partition, e.Error.Reason);
    }
    catch (Exception e)
    {
        logger.LogError(e, "[P{Partition}] Caught exception: {Message}", partition, e.Message);
    }
    finally
    {
        consumer.Close();
        logger.LogInformation("[P{Partition}] Consumer closed, processed {Count} events", partition, processedCount);
    }
}

// =============================================================================
// Process a batch of events with comprehensive retry handling
// =============================================================================
static async Task ProcessBatch(
    List<RequestEvent> batch,
    string connectionString,
    Dictionary<int, List<WorkflowTransition>> workflowTransitions,
    int processingDelayMs,
    ILogger logger,
    int partition,
    CancellationToken cancellationToken)
{
    await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
    {
        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        foreach (var evt in batch)
        {
            // Simulate processing delay
            if (processingDelayMs > 0)
            {
                await Task.Delay(processingDelayMs, cancellationToken);
            }

            await ProcessEvent(evt, connection, transaction, workflowTransitions, logger, partition, cancellationToken);
        }

        await transaction.CommitAsync(cancellationToken);
    }, logger, $"[P{partition}] process batch of {batch.Count} events", cancellationToken: cancellationToken);
}

// =============================================================================
// Process a single event - determine next state and update database
// =============================================================================
static async Task ProcessEvent(
    RequestEvent evt,
    NpgsqlConnection connection,
    NpgsqlTransaction transaction,
    Dictionary<int, List<WorkflowTransition>> workflowTransitions,
    ILogger logger,
    int partition,
    CancellationToken cancellationToken)
{
    // Get request info to determine request type
    await using var cmd = new NpgsqlCommand(
        "SELECT request_type_id, request_status_id FROM request_info WHERE request_id = @requestId",
        connection, transaction);
    cmd.Parameters.AddWithValue("requestId", evt.RequestId);

    await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
    {
        logger.LogWarning("[P{Partition}] Request {RequestId} not found", partition, evt.RequestId);
        return;
    }

    var requestTypeId = reader.GetInt32(0);
    var currentStatusId = reader.GetInt32(1);
    await reader.CloseAsync();

    // Get workflow transitions for this request type
    if (!workflowTransitions.TryGetValue(requestTypeId, out var transitions))
    {
        logger.LogWarning("[P{Partition}] No workflow defined for request type {RequestTypeId}",
            partition, requestTypeId);
        return;
    }

    // Find current transition
    var currentTransition = transitions.FirstOrDefault(t => t.ActionStateLinkId == evt.ActionStateLinkId);
    if (currentTransition == null)
    {
        logger.LogWarning("[P{Partition}] Current action state link {LinkId} not found in workflow",
            partition, evt.ActionStateLinkId);
        return;
    }

    // Skip if already terminal
    if (currentTransition.IsTerminal)
    {
        logger.LogDebug("[P{Partition}] Request {RequestId} is in terminal state, skipping",
            partition, evt.RequestId);
        return;
    }

    // Get next transition
    var nextTransition = transitions
        .Where(t => t.SortOrder > currentTransition.SortOrder)
        .OrderBy(t => t.SortOrder)
        .FirstOrDefault();

    if (nextTransition == null)
    {
        logger.LogWarning("[P{Partition}] No next state for request {RequestId}", partition, evt.RequestId);
        return;
    }

    // Handle ACCOUNT_LINK special case
    if (evt.Metadata != null)
    {
        var metadata = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(evt.Metadata);
        if (metadata != null && metadata.ContainsKey("linked_account_id"))
        {
            var linkedAccountId = Guid.Parse(metadata["linked_account_id"].GetString()!);

            // Insert into request_account_link (idempotent)
            await using var linkCmd = new NpgsqlCommand(@"
                INSERT INTO request_account_link (request_id, account_id, role, allocation_pct)
                VALUES (@requestId, @accountId, 'LINKED', 100.00)
                ON CONFLICT (request_id, account_id) DO NOTHING",
                connection, transaction);
            linkCmd.Parameters.AddWithValue("requestId", evt.RequestId);
            linkCmd.Parameters.AddWithValue("accountId", linkedAccountId);
            await linkCmd.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    // Insert next event into request_event_log
    var nextSeqNum = evt.SeqNum + 1;
    var idempotencyKey = $"{evt.RequestId}:{nextSeqNum}:{nextTransition.ActionStateLinkId}";

    await using var insertCmd = new NpgsqlCommand(@"
        INSERT INTO request_event_log (
            request_id, seq_num, action_state_link_id, status_id,
            event_ts, actor, metadata, idempotency_key
        )
        VALUES (@requestId, @seqNum, @actionStateLinkId, @statusId, @eventTs, @actor, @metadata, @idempotencyKey)
        ON CONFLICT (request_id, action_state_link_id, idempotency_key) DO NOTHING",
        connection, transaction);

    insertCmd.Parameters.AddWithValue("requestId", evt.RequestId);
    insertCmd.Parameters.AddWithValue("seqNum", nextSeqNum);
    insertCmd.Parameters.AddWithValue("actionStateLinkId", nextTransition.ActionStateLinkId);
    insertCmd.Parameters.AddWithValue("statusId", nextTransition.IsTerminal ? 3 : 2); // 3=COMPLETE, 2=IN_PROGRESS
    insertCmd.Parameters.AddWithValue("eventTs", DateTime.UtcNow);
    insertCmd.Parameters.AddWithValue("actor", "workflow-processor");
    insertCmd.Parameters.AddWithValue("metadata", evt.Metadata ?? (object)DBNull.Value);
    insertCmd.Parameters.AddWithValue("idempotencyKey", idempotencyKey);

    await insertCmd.ExecuteNonQueryAsync(cancellationToken);
}

// =============================================================================
// Data Transfer Objects
// =============================================================================
record RequestEvent
{
    public required Guid RequestId { get; init; }
    public required long SeqNum { get; init; }
    public required long ActionStateLinkId { get; init; }
    public required int StatusId { get; init; }
    public required DateTime EventTs { get; init; }
    public string? Actor { get; init; }
    public string? Metadata { get; init; }
    public required string IdempotencyKey { get; init; }
    public required Offset Offset { get; init; }
}

record WorkflowTransition
{
    public required long ActionStateLinkId { get; init; }
    public required int ActionTypeId { get; init; }
    public required int StateId { get; init; }
    public required int SortOrder { get; init; }
    public required bool IsInitial { get; init; }
    public required bool IsTerminal { get; init; }
}

record CDCEventData
{
    public Guid request_id { get; set; }
    public long seq_num { get; set; }
    public long? action_state_link_id { get; set; }
    public int? status_id { get; set; }
    public DateTime? event_ts { get; set; }
    public string? actor { get; set; }
    public JsonElement? metadata { get; set; }
    public string? idempotency_key { get; set; }
}
