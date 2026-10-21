# Lakefront Bike Share Semantic Model

A star schema semantic model built on top of the warehouse from my [report ingestion project](https://github.com/narlaq/report-ingestion), with calculation groups handling time intelligence and rolling trend periods. It's written in TMDL, the text format that Power BI, Fabric, and SQL Server Analysis Services all read, so the whole model can be reviewed on GitHub like any other code.

The DAX follows SQLBI's published guidance, and each measure carries a short description of the filter context it's built for and what its total row means.

## The model

| Table | Grain | Notes |
| --- | --- | --- |
| `Station Activity` | one row per station per day (62,312 rows, Jan 2022 to Sep 2026) | Trips, returns, riding time, revenue |
| `Weather` | one row per day (Chicago O'Hare, 1959 to Sep 2026) | Precipitation, snowfall, high and low temperature |
| `Station` | one row per station (36) | Station name and district |
| `Date` | one row per day, 1959 through 2026 (whole years) | Marked as the date table; also carries each day's weather as categories |
| `Time Intelligence` | calculation group (precedence 20) | Current, MTD, QTD, YTD, PY, YoY, YoY % |
| `Trend Period` | calculation group (precedence 10) | Selected Period, Rolling 7 Days, Rolling 28 Days, Rolling 12 Months |

All relationships are many-to-one and single direction, from `Date` and `Station` out to the two fact tables.

A couple of the design choices are worth explaining:

- **Weather is its own fact table.** Joining the weather onto the station rows would be simpler, but every day's rainfall would then be summed once per station (36 times). As a separate table related to `Date`, precipitation totals stay correct no matter what's on the rows.
- **The weather categories live on `Date`.** `Precipitation Category` and `High Temperature Band` are attributes of the day, so slicing ridership by weather goes through the same single relationship as everything else, with no bidirectional filtering.

## Comparing a partial year to the prior year

The bike share data runs through September 30, 2026. A standard prior-year calculation at the year level compares nine months of 2026 against all twelve months of 2025:

| Period | Trips | Change vs 2026 YTD |
| --- | ---: | ---: |
| 2026 (Jan to Sep) | 829,697 | |
| 2025, full year (standard `SAMEPERIODLASTYEAR`) | 1,045,266 | -20.6% |
| 2025, Jan to Sep (this model's `PY`) | 834,199 | -0.5% |

The `Date` table has an `Is Reported` column that marks every date up to the last reported day, and the `PY`, `YoY`, and `YoY %` items only shift the dates that have actually been reported (the pattern SQLBI describes for hiding future dates):

```dax
CALCULATE (
    SELECTEDMEASURE (),
    CALCULATETABLE (
        SAMEPERIODLASTYEAR ( 'Date'[Date] ),
        'Date'[Is Reported] = TRUE ()
    )
)
```

The rolling windows in `Trend Period` anchor on the last reported date in the current filter context for the same reason, so a "Rolling 28 Days" value for 2026 measures the last 28 days of data rather than the empty weeks at the end of December.

## Measure notes

| Measure | Built for | Total row |
| --- | --- | --- |
| `Average Ride Minutes` | any grain | Weighted by trips (total riding time over total trips), not an average of station averages |
| `Days Reported` | any grain | Counts each day once, however many stations reported it |
| `Average Daily Trips` | any grain | Trips over reported days, so months and weather categories with different day counts compare fairly |
| `Trips vs Dry Days %` | month, season, or weather category | Compares against dry days under the same other filters; blank at the single-day level unless that day was dry |
| `Hot Days per Year` | year, decade, or above | Days at or above 90°F divided by years observed in context |
| `YoY` / `YoY %` | any grain | Blank when either period has no value, rather than a fake 100% |

The prior-year expression is repeated in `PY`, `YoY`, and `YoY %` because calculation items can't share variables. DAX user-defined functions would remove that duplication, but they need a newer compatibility level than SSAS supports, and I wanted the model to deploy anywhere.

## How it was checked

`tools/Test-ModelCompiles.ps1` deploys the model to an Analysis Services Tabular server as an empty, temporary database, checks every column, measure, and calculation item for errors, evaluates all 17 measures under every combination of the two calculation groups (476 combinations), and then deletes the database. It needs no data source credentials.

To be clear about what that covers: it proves the model and its DAX are valid, not that the numbers are right. The figures in this README come from SQL against the same views. Refreshing the model against the data is the next step.

## Running it

1. Build the warehouse with the [report ingestion project](https://github.com/narlaq/report-ingestion), generating the full history with `python -m tools.generate_reports --start 2022-01-01 --end 2026-09-30`.
2. Run `sql/analytics_views.sql` against `ReportIngestionDemo` to create the `Analytics` views.
3. Open `model/definition` in Tabular Editor, or deploy it to SSAS, Power BI, or Fabric. The `Server` and `Database` parameters default to `localhost` and `ReportIngestionDemo`.
4. Optional: `.\tools\Test-ModelCompiles.ps1 -Server localhost` to run the compile check yourself.

## Data

Weather data comes from the NOAA National Centers for Environmental Information **Global Historical Climatology Network – Daily (GHCN-Daily)**, a U.S. government work in the public domain. Lakefront Bike Share is fictional, and its ridership is simulated from the real O'Hare weather for each day, so any weather effect on ridership reflects the simulation, not a finding.
