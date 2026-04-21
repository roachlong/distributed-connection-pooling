using EventLogs.Common;
using EventLogs.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Npgsql;
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
var tradesPerAccount = configuration.GetValue<int>("TradesPerAccount", 3);

using var loggerFactory = LoggerFactory.Create(builder => builder.AddConsole());
var logger = loggerFactory.CreateLogger<Program>();

logger.LogInformation("=== Trade Generator [{Region}] ===", region);
logger.LogInformation("Connection: {Connection}", connectionString.Substring(0, Math.Min(50, connectionString.Length)));
logger.LogInformation("Batch Size: {BatchSize}, Throttle: {ThrottleMs}ms, Trades Per Account: {TradesPerAccount}",
    batchSize, throttleMs, tradesPerAccount);

// Load locality configuration for this region
var configKey = $"Localities_{region.Replace("-", "_")}";
var localitiesJson = configuration.GetValue<string>(configKey)
    ?? throw new InvalidOperationException($"{configKey} not configured");
var localities = JsonSerializer.Deserialize<List<short>>(localitiesJson)
    ?? throw new InvalidOperationException($"Failed to parse {configKey}");

logger.LogInformation("Processing localities: {Localities}", string.Join(",", localities));

var optionsBuilder = new DbContextOptionsBuilder<EventLogsContext>();
optionsBuilder.UseNpgsql(connectionString);

// Keyset pagination state
short? lastLocality = null;
Guid? lastAccountId = null;
var random = new Random();
var processedCount = 0;
var loopCount = 0;

string[] symbols = ["AAPL", "MSFT", "GOOGL", "AMZN", "TSLA", "META", "NVDA", "JPM", "BAC", "GS"];
string[] sides = ["BUY", "SELL"];

logger.LogInformation("Starting continuous trade generation loop...");

while (true)
{
    loopCount++;
    using var dbContext = new EventLogsContext(optionsBuilder.Options);

    try
    {
        // Generate trade data in memory
        var tradeValues = new List<string>();
        for (int i = 0; i < batchSize * tradesPerAccount; i++)
        {
            var tradeId = Guid.NewGuid();
            var symbol = symbols[random.Next(symbols.Length)];
            var side = sides[random.Next(sides.Length)];
            var quantity = Math.Round((decimal)(random.NextDouble() * 999 + 1), 4);
            var price = Math.Round((decimal)(random.NextDouble() * 9900 + 100), 4);
            var now = DateTime.UtcNow;

            tradeValues.Add($"('{tradeId}', '{symbol}', '{side}', {quantity}, {price}, 'USD', 2, '{now:yyyy-MM-dd HH:mm:ss.ffffff}')");
        }

        var paginationClause = lastLocality.HasValue && lastAccountId.HasValue
            ? $"AND (ai.locality > {lastLocality.Value} OR (ai.locality = {lastLocality.Value} AND ai.account_id > '{lastAccountId.Value}'))"
            : "";

        // Single CTE-based query: select completed accounts, insert trades, and return pagination info
        var sql = $@"
            WITH completed_accounts AS (
                SELECT ai.locality, ai.account_id, ai.account_number, ri.request_id,
                       ROW_NUMBER() OVER (ORDER BY ai.locality, ai.account_id) as rn
                FROM account_info ai
                JOIN request_info ri ON ri.primary_account_id = ai.account_id
                JOIN request_type rt ON rt.request_type_id = ri.request_type_id
                JOIN request_status_head rsh ON rsh.request_id = ri.request_id
                JOIN request_action_state_link rasl ON rasl.action_state_link_id = rsh.action_state_link_id
                WHERE ai.locality = ANY(ARRAY[{string.Join(",", localities)}])
                  AND rt.request_type_code = 'ACCOUNT_ONBOARDING'
                  AND rasl.is_terminal = true
                  AND rsh.status_id = 3
                  {paginationClause}
                ORDER BY ai.locality, ai.account_id
                LIMIT {batchSize}
            ),
            trade_data AS (
                SELECT * FROM (VALUES
                    {string.Join(",\n                    ", tradeValues)}
                ) AS t(trade_id, symbol, side, quantity, price, currency, status_id, created_ts)
            ),
            numbered_trades AS (
                SELECT *, ROW_NUMBER() OVER () as trade_rn
                FROM trade_data
            ),
            inserted AS (
                INSERT INTO trade_info (trade_id, request_id, account_id, symbol, side, quantity, price, currency, status_id, created_ts)
                SELECT
                    nt.trade_id::uuid,
                    ca.request_id,
                    ca.account_id,
                    nt.symbol,
                    nt.side,
                    nt.quantity,
                    nt.price,
                    nt.currency,
                    nt.status_id,
                    nt.created_ts::timestamptz
                FROM numbered_trades nt
                CROSS JOIN completed_accounts ca
                WHERE nt.trade_rn BETWEEN ((ca.rn - 1) * {tradesPerAccount} + 1) AND (ca.rn * {tradesPerAccount})
                ON CONFLICT (trade_id) DO NOTHING
                RETURNING account_id
            )
            SELECT
                (SELECT COUNT(DISTINCT account_id) FROM inserted) as accounts_count,
                (SELECT COUNT(*) FROM inserted) as trades_count,
                (SELECT locality FROM completed_accounts ORDER BY locality DESC, account_id DESC LIMIT 1) as last_locality,
                (SELECT account_id FROM completed_accounts ORDER BY locality DESC, account_id DESC LIMIT 1) as last_account_id";

        var (accountsCount, tradesCount, lastLoc, lastAcct) = await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
        {
            await using var conn = dbContext.Database.GetDbConnection() as NpgsqlConnection;
            if (conn == null) throw new InvalidOperationException("Expected NpgsqlConnection");

            await conn.OpenAsync();
            await using var cmd = new NpgsqlCommand(sql, conn);
            await using var reader = await cmd.ExecuteReaderAsync();

            if (await reader.ReadAsync())
            {
                var accountsCount = reader.IsDBNull(0) ? 0 : reader.GetInt64(0);
                var tradesCount = reader.IsDBNull(1) ? 0 : reader.GetInt64(1);
                var lastLoc = reader.IsDBNull(2) ? (short?)null : reader.GetInt16(2);
                var lastAcct = reader.IsDBNull(3) ? (Guid?)null : reader.GetGuid(3);
                return (accountsCount, tradesCount, lastLoc, lastAcct);
            }

            return (0L, 0L, (short?)null, (Guid?)null);
        }, logger, $"[Loop {loopCount}] batch insert trades");

        if (accountsCount == 0)
        {
            logger.LogInformation("Loop {Loop}: No more accounts with completed onboarding. Resetting pagination.", loopCount);
            lastLocality = null;
            lastAccountId = null;
            await Task.Delay(throttleMs);
            continue;
        }

        // Update pagination cursor
        lastLocality = lastLoc;
        lastAccountId = lastAcct;

        var tradesCreated = (int)tradesCount;
        processedCount += tradesCreated;

        logger.LogInformation("Loop {Loop}: Created {Trades} trades for {Accounts} accounts (total: {Total})",
            loopCount, tradesCreated, accountsCount, processedCount);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Error processing batch in loop {Loop}", loopCount);
    }

    await Task.Delay(throttleMs);
}
