using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Links requests to multiple accounts (many-to-many relationship).
/// </summary>
public partial class RequestAccountLink
{
    public Guid RequestId { get; set; }

    public string AccountNumber { get; set; } = null!;

    public string? Role { get; set; }

    public decimal? AllocationPct { get; set; }
}
