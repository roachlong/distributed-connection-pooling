using System;
using System.Collections.Generic;

namespace EventLogs.Data;

/// <summary>
/// Identifies the minimum selected value.
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
