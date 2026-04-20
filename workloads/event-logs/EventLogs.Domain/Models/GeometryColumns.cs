using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Shows all defined geometry columns. Matches PostGIS&apos; geometry_columns functionality.
/// </summary>
public partial class GeometryColumns
{
    public long? CoordDimension { get; set; }

    public long? Srid { get; set; }

    public string? Type { get; set; }
}
