using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Account information with manual hash-based partitioning.
/// locality is auto-computed from account_number via CRC32 hash.
/// </summary>
public partial class AccountInfo
{
    public string AccountNumber { get; set; } = null!;

    public string AccountName { get; set; } = null!;

    public string? Strategy { get; set; }

    public string? BaseCurrency { get; set; }

    // Read-only: computed by database from account_number
    public short Locality { get; set; }
}
