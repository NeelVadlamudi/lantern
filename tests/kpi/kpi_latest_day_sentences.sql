-- Every scope in latest_day has its comparison sentence, also on a day type with no earlier
-- day to compare with (a holiday): a null sentence would leave the card blank.
with scopes as (
    select unnest(cast(payload.latest_day -> 'scopes' as json[])) as scope_json
    from {{ ref('board_payload') }} as payload
)

select scopes.scope_json ->> 'scope_id' as scope_id
from scopes
where scopes.scope_json ->> 'comparison' is null
