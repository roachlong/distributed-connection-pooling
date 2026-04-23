namespace EventLogs.Analytics.Models;

public class TradeAggregate
{
    public string Side { get; set; } = "";
    public string Status { get; set; } = "";
    public string Symbol { get; set; } = "";
    public string Region { get; set; } = "";
    public int Count { get; set; }
    public decimal TotalQuantity { get; set; }
    public decimal AveragePrice { get; set; }
}

public class TradeDetail
{
    public Guid TradeId { get; set; }
    public Guid RequestId { get; set; }
    public Guid AccountId { get; set; }
    public string Symbol { get; set; } = "";
    public string Side { get; set; } = "";
    public decimal Quantity { get; set; }
    public decimal? Price { get; set; }
    public string? Currency { get; set; }
    public string Status { get; set; } = "";
    public string Region { get; set; } = "";
    public DateTime CreatedAt { get; set; }
}
