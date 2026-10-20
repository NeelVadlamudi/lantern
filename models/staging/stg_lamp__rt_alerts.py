"""stg_lamp__rt_alerts

Grain: one row per alert version, informed entity and active period (as published in
LAMP_RT_ALERTS), subway and light rail only (route_type 1 and 0). Facility alerts (elevators,
escalators: effect ACCESSIBILITY_ISSUE) are left out. Datetimes are local (America/New_York)
wall-clock times, as LAMP publishes them.

Python model so a bad byte in the feed does not stop the build. DuckDB refuses a Parquet string
that is not valid UTF-8 (the 2026-10-19 refresh failed on byte 0xa2). The query below runs in
DuckDB as is; only when DuckDB rejects the encoding is the file read again with pyarrow, the
invalid bytes in the text columns replaced with U+FFFD, and the same query run on that copy.
Rows are never dropped, so row counts do not depend on which path ran.
"""

import os
import re
import shutil
import tempfile
import urllib.request

TEXT_COLUMNS = [
    "cause",
    "effect",
    "effect_detail",
    "severity_level",
    "header_text.translation.text",
    "informed_entity.route_id",
    "informed_entity.stop_id",
]
SOURCE_COLUMNS = [
    "id",
    "last_modified_timestamp",
    "created_datetime",
    "closed_datetime",
    "active_period.start_datetime",
    "active_period.end_datetime",
    "informed_entity.route_type",
    "informed_entity.direction_id",
] + TEXT_COLUMNS

QUERY = """
select distinct
    cast(id as bigint) as alert_id,
    cast(last_modified_timestamp as bigint) as alert_version_timestamp,
    cast(created_datetime as timestamp) as created_at,
    cast(closed_datetime as timestamp) as closed_at,
    cast(cause as varchar) as cause,
    cast(effect as varchar) as effect,
    cast(effect_detail as varchar) as effect_detail,
    cast(severity_level as varchar) as severity_level,
    cast("header_text.translation.text" as varchar) as header_text,
    cast("active_period.start_datetime" as timestamp) as active_start_at,
    cast("active_period.end_datetime" as timestamp) as active_end_at,
    cast("informed_entity.route_id" as varchar) as route_id,
    cast("informed_entity.route_type" as integer) as route_type,
    cast("informed_entity.direction_id" as integer) as direction_id,
    nullif(cast("informed_entity.stop_id" as varchar), '') as stop_id
from {source}
where
    "informed_entity.route_type" in (0, 1)
    and effect is distinct from 'ACCESSIBILITY_ISSUE'
"""


def is_encoding_error(error):
    # DuckDB reports the bad value in its message; the Python client can then fail to decode
    # the message itself, which surfaces as UnicodeDecodeError.
    if isinstance(error, UnicodeDecodeError):
        return True
    return "invalid string encoding" in str(error).lower()


def lenient_text(chunk):
    import pyarrow as pa

    try:
        chunk.validate(full=True)
        return chunk
    except pa.ArrowInvalid:
        values = chunk.view(pa.binary()).to_pylist()
        return pa.array(
            [None if v is None else v.decode("utf-8", errors="replace") for v in values],
            pa.string(),
        )


def read_lenient(location):
    """Read the alerts Parquet with pyarrow and replace bytes that are not valid UTF-8."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    tmp = None
    path = location
    if re.match(r"https?://", location):
        tmp = tempfile.NamedTemporaryFile(suffix=".parquet", delete=False)
        with urllib.request.urlopen(location, timeout=600) as response, tmp:
            shutil.copyfileobj(response, tmp)
        path = tmp.name
    try:
        table = pq.read_table(path, columns=SOURCE_COLUMNS)
    finally:
        if tmp is not None:
            os.unlink(tmp.name)
    for name in TEXT_COLUMNS:
        index = table.schema.get_field_index(name)
        chunks = [lenient_text(c) for c in table.column(index).chunks]
        table = table.set_column(index, name, pa.chunked_array(chunks, pa.string()))
    return table


def model(dbt, session):
    dbt.config(materialized="table")
    source = dbt.source("lamp", "lamp_rt_alerts")
    location = dbt.config.get("alerts_location")
    try:
        return session.sql(QUERY.format(source=f"({source.sql_query()}) as source")).arrow()
    except Exception as error:
        if not is_encoding_error(error):
            raise
    session.register("lamp_rt_alerts_lenient", read_lenient(location))
    return session.sql(QUERY.format(source="lamp_rt_alerts_lenient")).arrow()
