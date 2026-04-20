using EventLogs.Common;
using EventLogs.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using System.Security.Cryptography;
using System.Text;
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

var batchSize = configuration.GetValue<int>("BatchSize", 100);
var throttleMs = configuration.GetValue<int>("ThrottleMs", 1000);
var requestedBy = configuration.GetValue<string>("RequestedBy", "system");

using var loggerFactory = LoggerFactory.Create(builder => builder.AddConsole());
var logger = loggerFactory.CreateLogger<Program>();

logger.LogInformation("=== Request Generator [{Region}] ===", region);
logger.LogInformation("Connection: {Connection}", connectionString.Substring(0, Math.Min(50, connectionString.Length)));
logger.LogInformation("Batch Size: {BatchSize}, Throttle: {ThrottleMs}ms", batchSize, throttleMs);

// Load locality configuration for this region
var configKey = $"Localities_{region.Replace("-", "_")}";
var localitiesJson = configuration.GetValue<string>(configKey)
    ?? throw new InvalidOperationException($"{configKey} not configured");
var localities = JsonSerializer.Deserialize<List<short>>(localitiesJson)
    ?? throw new InvalidOperationException($"Failed to parse {configKey}");

logger.LogInformation("Processing localities: {Localities}", string.Join(",", localities));

var optionsBuilder = new DbContextOptionsBuilder<EventLogsContext>();
optionsBuilder.UseNpgsql(connectionString);

// Test connection
using (var testContext = new EventLogsContext(optionsBuilder.Options))
{
    try
    {
        await testContext.Database.ExecuteSqlRawAsync("SELECT 1");
        logger.LogInformation("Database connection successful");
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Database connection failed");
        return 1;
    }
}

// Load request types and action state links for random selection
Dictionary<int, string> requestTypes;
Dictionary<int, List<long>> requestTypeActionStates; // requestTypeId -> list of action_state_link_ids

using (var setupContext = new EventLogsContext(optionsBuilder.Options))
{
    requestTypes = await setupContext.RequestType
        .ToDictionaryAsync(rt => rt.RequestTypeId, rt => rt.RequestTypeCode);

    requestTypeActionStates = await setupContext.RequestActionStateLink
        .Where(rasl => rasl.IsInitial)
        .GroupBy(rasl => rasl.RequestTypeId)
        .ToDictionaryAsync(
            g => g.Key,
            g => g.Select(rasl => rasl.ActionStateLinkId).ToList()
        );

    logger.LogInformation("Loaded {Count} request types", requestTypes.Count);
}

// Keyset pagination state (locality, account_id)
short? lastLocality = null;
Guid? lastAccountId = null;
var random = new Random();
var processedCount = 0;
var loopCount = 0;

logger.LogInformation("Starting continuous request generation loop...");

while (true)
{
    loopCount++;
    using var dbContext = new EventLogsContext(optionsBuilder.Options);

    try
    {
        // Fetch next batch of accounts using keyset pagination
        IQueryable<AccountInfo> query = dbContext.AccountInfo
            .Where(a => localities.Contains(a.Locality));

        if (lastLocality.HasValue && lastAccountId.HasValue)
        {
            query = query.Where(a =>
                a.Locality > lastLocality.Value ||
                (a.Locality == lastLocality.Value && a.AccountId > lastAccountId.Value));
        }

        var accounts = await query
            .OrderBy(a => a.Locality)
            .ThenBy(a => a.AccountId)
            .Take(batchSize)
            .ToListAsync();

        if (accounts.Count == 0)
        {
            logger.LogInformation("No more accounts in range. Resetting pagination to beginning.");
            lastLocality = null;
            lastAccountId = null;
            await Task.Delay(throttleMs);
            continue;
        }

        logger.LogInformation("Loop {Loop}: Processing batch of {Count} accounts...", loopCount, accounts.Count);

        foreach (var account in accounts)
        {
            // Check if account has been processed before (has request_info)
            var existingRequest = await dbContext.RequestInfo
                .Where(r => r.PrimaryAccountId == account.AccountId)
                .OrderByDescending(r => r.CreatedTs)
                .FirstOrDefaultAsync();

            int requestTypeId;
            string requestTypeCode;
            string description;

            if (existingRequest == null)
            {
                // New account - use ACCOUNT_ONBOARDING
                var onboardingType = requestTypes.FirstOrDefault(rt => rt.Value == "ACCOUNT_ONBOARDING");
                if (onboardingType.Key == 0)
                {
                    logger.LogWarning("ACCOUNT_ONBOARDING request type not found. Skipping account {AccountId}", account.AccountId);
                    continue;
                }
                requestTypeId = onboardingType.Key;
                requestTypeCode = onboardingType.Value;
                description = $"Onboarding for account {account.AccountNumber}";
            }
            else
            {
                // Existing account - check if closed
                var isClosed = existingRequest.RequestStatusId == 4; // Assuming 4 = CLOSED
                if (isClosed)
                {
                    continue; // Skip closed accounts
                }

                // Random request type (excluding ACCOUNT_ONBOARDING)
                var eligibleTypes = requestTypes.Where(rt => rt.Value != "ACCOUNT_ONBOARDING").ToList();
                var selectedType = eligibleTypes[random.Next(eligibleTypes.Count)];
                requestTypeId = selectedType.Key;
                requestTypeCode = selectedType.Value;
                description = $"{requestTypeCode} for account {account.AccountNumber}";
            }

            // Get initial action state link for this request type
            if (!requestTypeActionStates.TryGetValue(requestTypeId, out var actionStateLinks) || actionStateLinks.Count == 0)
            {
                logger.LogWarning("No initial action state link found for request type {RequestTypeId}. Skipping.", requestTypeId);
                continue;
            }

            var actionStateLinkId = actionStateLinks.First();

            // Generate deterministic idempotency key
            var idempotencyKey = GenerateIdempotencyKey(account.AccountId, requestTypeId, loopCount);

            // Check if this request was already created (idempotency check)
            var existingEvent = await dbContext.RequestEventLog
                .Where(e => e.IdempotencyKey == idempotencyKey)
                .AnyAsync();

            if (existingEvent)
            {
                continue; // Skip duplicate
            }

            var requestId = Guid.NewGuid();
            var now = DateTime.UtcNow;

            // Prepare metadata (for ACCOUNT_LINK, add random account)
            var metadata = new Dictionary<string, object>();
            if (requestTypeCode == "ACCOUNT_LINK")
            {
                // Pick a random account regardless of locality
                var randomAccount = await dbContext.AccountInfo
                    .OrderBy(a => Guid.NewGuid()) // Simple random - not efficient but works for demo
                    .Select(a => a.AccountId)
                    .FirstOrDefaultAsync();

                if (randomAccount != Guid.Empty)
                {
                    metadata["linked_account_id"] = randomAccount.ToString();
                }
            }

            var metadataJson = JsonSerializer.Serialize(metadata);

            // Insert request_info and request_event_log atomically with retry logic
            await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
            {
                // Insert request_info
                await dbContext.Database.ExecuteSqlRawAsync(@"
                    INSERT INTO request_info (request_id, request_type_id, primary_account_id, requested_by, description, request_status_id, created_ts)
                    VALUES ({0}, {1}, {2}, {3}, {4}, 1, {5})",
                    requestId, requestTypeId, account.AccountId, requestedBy, description, now);

                // Insert request_event_log (this triggers CDC)
                await dbContext.Database.ExecuteSqlRawAsync(@"
                    INSERT INTO request_event_log (request_id, seq_num, action_state_link_id, status_id, event_ts, actor, metadata, idempotency_key)
                    VALUES ({0}, 1, {1}, 1, {2}, {3}, {4}::jsonb, {5})",
                    requestId, actionStateLinkId, now, requestedBy, metadataJson, idempotencyKey);
            }, logger, $"create request for account {account.AccountNumber}");

            processedCount++;
        }

        // Update pagination cursor
        lastLocality = accounts.Last().Locality;
        lastAccountId = accounts.Last().AccountId;

        logger.LogInformation("Loop {Loop}: Created requests for {Count} accounts (total processed: {Total})",
            loopCount, accounts.Count, processedCount);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Error processing batch in loop {Loop}", loopCount);
    }

    // Throttle
    await Task.Delay(throttleMs);
}

static string GenerateIdempotencyKey(Guid accountId, int requestTypeId, int loopCount)
{
    var input = $"{accountId}:{requestTypeId}:{loopCount}";
    var hash = SHA256.HashData(Encoding.UTF8.GetBytes(input));
    return Convert.ToHexString(hash).ToLowerInvariant();
}
