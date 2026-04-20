using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Shows all defined geography columns. Matches PostGIS&apos; geography_columns functionality.
/// </summary>
public partial class GeographyColumns
{
    public long? CoordDimension { get; set; }

    public long? Srid { get; set; }

    public string? Type { get; set; }
}
