namespace EventLogs.Analytics.Models;

public class PageCursor
{
    public int PageNumber { get; set; }
    public Guid StartRequestId { get; set; }
    public long RowOffset { get; set; }
}

public class TradePageCursor
{
    public int PageNumber { get; set; }
    public Guid StartTradeId { get; set; }
    public long RowOffset { get; set; }
}
