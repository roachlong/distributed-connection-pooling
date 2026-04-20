using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class RequestAccountLink
{
    public Guid RequestId { get; set; }

    public Guid AccountId { get; set; }

    public string? Role { get; set; }

    public decimal? AllocationPct { get; set; }
}
