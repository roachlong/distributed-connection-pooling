#!/usr/bin/env bash
set -euo pipefail

# Connection info
CRDB_URL=${CRDB_URL:-"postgresql://me:secret@localhost:26257/defaultdb?sslmode=prefer"}

mkdir -p logs
OUTPUT="logs/ranges_report.csv"

# Remove any old file
rm -f "$OUTPUT"

echo "Generating unified CSV: $OUTPUT"
echo

tmpfile=$(mktemp)
header_written=0

# 1) Stream indexes directly into the while loop using TSV output
while IFS=$'\t' read -r db schema tbl idx; do
  # Skip header row
  if [[ "$db" == "table_catalog" ]]; then
    continue
  fi

  # Skip blank lines
  [[ -z "$db" ]] && continue

  echo "Processing $db.$schema.$tbl@$idx"

  # 2) Fetch the RANGE DETAILS for this index
  cockroach sql \
    --url "$CRDB_URL" \
    --format=tsv \
    --execute "
      SHOW RANGES FROM INDEX \"${db}\".\"${schema}\".\"${tbl}\"@\"${idx}\" WITH DETAILS;
    " \
    --no-line-editor \
    > "$tmpfile"

  # If file is empty, skip
  if [[ ! -s "$tmpfile" ]]; then
    echo "  (no ranges returned for $db.$schema.$tbl@$idx, skipping)"
    continue
  fi

  # 3) First time: write header
  if [[ $header_written -eq 0 ]]; then
    {
      echo -n "db_name,schema_name,table_name,index_name,"
      head -n 1 "$tmpfile" | sed $'s/\t/,/g'
    } > "$OUTPUT"
    header_written=1
  fi

  # 4) Append all data rows (skip the SHOW RANGES header)
  tail -n +2 "$tmpfile" | while IFS= read -r line; do
    echo "${db},${schema},${tbl},${idx},$(echo "$line" | sed $'s/\t/,/g')" >> "$OUTPUT"
  done

done < <(
  cockroach sql \
    --url "$CRDB_URL" \
    --format=tsv \
    --execute "
      SELECT DISTINCT
        table_catalog,
        table_schema,
        table_name,
        index_name
      FROM information_schema.statistics
      WHERE index_name IS NOT NULL
        AND table_schema NOT IN ('pg_catalog', 'information_schema', 'crdb_internal', 'system')
      ORDER BY table_catalog, table_schema, table_name, index_name;
    " \
    --no-line-editor
)

rm -f "$tmpfile"

echo
if [[ $header_written -eq 0 ]]; then
  echo "No ranges written (no indexes or no data)."
else
  echo "Done! Output written to: $OUTPUT"
fi
