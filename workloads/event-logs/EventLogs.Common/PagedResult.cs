namespace EventLogs.Common;

/// <summary>
/// Represents a page of results with cursor information for keyset pagination.
/// </summary>
public class PagedResult<T, TCursor> where T : class
{
    public List<T> Items { get; set; } = new();
    public TCursor? NextCursor { get; set; }
    public bool HasMore { get; set; }
    public int PageSize { get; set; }
}

/// <summary>
/// Cursor for account_info pagination (locality + account_id).
/// </summary>
public record AccountCursor(short Locality, Guid AccountId);

/// <summary>
/// Cursor for trade_info pagination (created_ts + trade_id).
/// </summary>
public record TradeCursor(DateTime CreatedTs, Guid TradeId);

/// <summary>
/// Cursor for request_info pagination (created_ts + request_id).
/// </summary>
public record RequestCursor(DateTime CreatedTs, Guid RequestId);
