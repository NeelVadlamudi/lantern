{#- Human label for a duration in seconds, e.g. 3725 -> '1 h 2 min'.

    Units, smallest to largest: s, min, h, day, month (30 days), year (365 days).
    The label shows the two largest units that apply: 'N s', 'M min S s', 'H h M min',
    'D days H h', 'Mo months D days', 'Y years Mo months'. A second unit of 0 is dropped
    ('1 min', '2 days'). Day, month and year are singular for 1 ('1 day', '2 days').

    Rounding: only what is cut off below the second unit is rounded, to the nearest second
    unit, halves up, and a full unit carries into the next one:
      119 s -> '1 min 59 s' (nothing is cut, so no rounding)
      3599 s -> '59 min 59 s'
      3655 s (1 h 0 min 55 s) -> '1 h 1 min'
      3750 s (1 h 2 min 30 s) -> '1 h 3 min'
      86380 s (23 h 59 min 40 s) -> '1 day'
      88200 s (1 day 0 h 30 min) -> '1 day 1 h'
    Fractions of a second are cut the same way (59.5 s -> '1 min'). The unit pair is picked
    after rounding, so a carry can move the label up a level, as in 86380 s -> '1 day'.
    At the year level the remainder is rounded to whole 30-day months, and 12 months carry
    into the next year (a year is 365 days, so 12 months is the most a remainder can round to).
    Negative durations get a leading '-' on the label of the absolute value, unless that label
    is '0 s'. NULL stays NULL.
    The board's own formatter is checked against out/duration_label_cases.json, which is
    generated from this macro.
-#}
{% macro format_duration(seconds_expr) -%}
    list_transform(
        [cast({{ seconds_expr }} as double)],
        x -> case
            when x is null then null
            else
                (case when x < 0 and floor(abs(x) + 0.5) >= 1 then '-' else '' end)
                || list_transform(
                    [abs(x)],
                    a -> case
                        when floor(a + 0.5) < 60 then cast(floor(a + 0.5) as bigint) || ' s'
                        when floor(a + 0.5) < 3600 then list_transform(
                            [cast(floor(a + 0.5) as bigint)],
                            s -> (s // 60) || ' min' || case when s % 60 > 0 then ' ' || (s % 60) || ' s' else '' end
                        )[1]
                        when floor(a / 60 + 0.5) < 1440 then list_transform(
                            [cast(floor(a / 60 + 0.5) as bigint)],
                            m -> (m // 60) || ' h' || case when m % 60 > 0 then ' ' || (m % 60) || ' min' else '' end
                        )[1]
                        when floor(a / 3600 + 0.5) < 720 then list_transform(
                            [cast(floor(a / 3600 + 0.5) as bigint)],
                            h -> (h // 24) || case when h // 24 = 1 then ' day' else ' days' end
                            || case when h % 24 > 0 then ' ' || (h % 24) || ' h' else '' end
                        )[1]
                        when floor(a / 86400 + 0.5) < 365 then list_transform(
                            [cast(floor(a / 86400 + 0.5) as bigint)],
                            d -> (d // 30) || case when d // 30 = 1 then ' month' else ' months' end
                            || case
                                when d % 30 = 0 then ''
                                when d % 30 = 1 then ' 1 day'
                                else ' ' || (d % 30) || ' days'
                            end
                        )[1]
                        else list_transform(
                            [cast(floor(a / 31536000) as bigint)],
                            y -> list_transform(
                                [cast(floor((a - y * 31536000) / 2592000 + 0.5) as bigint)],
                                mo -> list_transform(
                                    [case when mo >= 12 then y + 1 else y end],
                                    yy -> yy || case when yy = 1 then ' year' else ' years' end
                                    || case
                                        when mo >= 12 or mo = 0 then ''
                                        when mo = 1 then ' 1 month'
                                        else ' ' || mo || ' months'
                                    end
                                )[1]
                            )[1]
                        )[1]
                    end
                )[1]
        end
    )[1]
{%- endmacro %}
