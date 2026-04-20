using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class TradeInfo
{
    public Guid TradeId { get; set; }

    public Guid RequestId { get; set; }

    public Guid AccountId { get; set; }

    public string Symbol { get; set; } = null!;

    public string Side { get; set; } = null!;

    public decimal Quantity { get; set; }

    public decimal? Price { get; set; }

    public string? Currency { get; set; }

    public int StatusId { get; set; }

    public DateTime CreatedTs { get; set; }

    public DateTime? UpdatedTs { get; set; }

    public virtual RequestStatus Status { get; set; } = null!;
}
