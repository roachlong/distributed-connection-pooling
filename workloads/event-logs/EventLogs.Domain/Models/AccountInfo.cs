using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class AccountInfo
{
    public Guid AccountId { get; set; }

    public string AccountNumber { get; set; } = null!;

    public string AccountName { get; set; } = null!;

    public string? Strategy { get; set; }

    public string? BaseCurrency { get; set; }

    public short Locality { get; set; }
}
