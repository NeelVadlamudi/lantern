-- Every effect detail code in the MBTA alerts archive has a reader label in the seed
-- alert_effect_labels (display_effect_label on service_changes is never null).
select distinct alerts.effect_detail
from {{ ref('stg_lamp__rt_alerts') }} as alerts
left join {{ ref('alert_effect_labels') }} as labels on alerts.effect_detail = labels.effect_code
where alerts.effect_detail is not null and labels.effect_code is null
