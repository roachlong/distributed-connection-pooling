using System;
using System.Collections.Generic;

namespace EventLogs.Data;

/// <summary>
/// Identifies the minimum selected value.
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
