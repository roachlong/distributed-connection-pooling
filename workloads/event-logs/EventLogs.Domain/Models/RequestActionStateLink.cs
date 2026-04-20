using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class RequestActionStateLink
{
    public long ActionStateLinkId { get; set; }

    public int RequestTypeId { get; set; }

    public int ActionTypeId { get; set; }

    public int StateId { get; set; }

    public bool IsInitial { get; set; }

    public bool IsTerminal { get; set; }

    public int SortOrder { get; set; }

    public virtual RequestActionType ActionType { get; set; } = null!;

    public virtual RequestType RequestType { get; set; } = null!;

    public virtual RequestState State { get; set; } = null!;
}
