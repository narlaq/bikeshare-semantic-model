/*
    Analytics layer for the Lakefront Bike Share semantic model.
    Reads the warehouse built by the report-ingestion project (database ReportIngestionDemo).

    The views use business-friendly column names so the model can import them as-is:
        [Analytics].[Date]              one row per day, 1959-01-01 through 2026-12-31 (whole years)
        [Analytics].[Station]           one row per bike-share station
        [Analytics].[Station Activity]  one row per station per day
        [Analytics].[Weather]           one row per day of Chicago O'Hare weather
*/
USE [ReportIngestionDemo];
GO

IF SCHEMA_ID('Analytics') IS NULL EXEC ('CREATE SCHEMA [Analytics];');
GO

/*
    Both facts end on the last day the bike-share reports cover, so a prior-year comparison
    never compares a partial year against a full one. [Is Reported] marks those dates.
    The O'Hare weather for each day is carried here as categories, so ridership can be
    sliced by weather through the single Date relationship.
*/
CREATE OR ALTER VIEW [Analytics].[Date]
    AS
WITH [Digit] AS
(
    SELECT
        [Digits].[Value]
    FROM
        ( VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9) ) [Digits] ([Value])
)
, [Calendar] AS
(
    SELECT
        DATEADD(DAY, [DayNumber].[Value], CAST ( '1959-01-01' AS DATE )) [Date]
    FROM
        (
            SELECT
                [Ones].[Value]
                    + [Tens].[Value] * 10
                    + [Hundreds].[Value] * 100
                    + [Thousands].[Value] * 1000
                    + [TenThousands].[Value] * 10000 [Value]
            FROM
                [Digit] [Ones]
                CROSS JOIN [Digit] [Tens]
                CROSS JOIN [Digit] [Hundreds]
                CROSS JOIN [Digit] [Thousands]
                CROSS JOIN [Digit] [TenThousands]
        ) [DayNumber]
    WHERE
        [DayNumber].[Value] <= DATEDIFF(DAY, '1959-01-01', '2026-12-31')
)
, [LastReport] AS
(
    SELECT
        MAX([FactStationActivity].[ActivityDate]) [LastReportedDate]
    FROM
        [Warehouse].[FactStationActivity]
)
SELECT
    [Calendar].[Date]
    , YEAR([Calendar].[Date]) [Year]
    , CONCAT('Q', DATEPART(QUARTER, [Calendar].[Date])) [Quarter]
    , CONCAT(YEAR([Calendar].[Date]), ' Q', DATEPART(QUARTER, [Calendar].[Date])) [Year Quarter]
    , YEAR([Calendar].[Date]) * 10 + DATEPART(QUARTER, [Calendar].[Date]) [Year Quarter Number]
    , MONTH([Calendar].[Date]) [Month Number]
    , LEFT(DATENAME(MONTH, [Calendar].[Date]), 3) [Month]
    , CONCAT(LEFT(DATENAME(MONTH, [Calendar].[Date]), 3), ' ', YEAR([Calendar].[Date])) [Year Month]
    , YEAR([Calendar].[Date]) * 100 + MONTH([Calendar].[Date]) [Year Month Number]
    , LEFT(DATENAME(WEEKDAY, [Calendar].[Date]), 3) [Day of Week]
    , DATEDIFF(DAY, '1900-01-01', [Calendar].[Date]) % 7 + 1 [Day of Week Number]     -- Monday = 1, independent of DATEFIRST
    , CASE WHEN DATEDIFF(DAY, '1900-01-01', [Calendar].[Date]) % 7 >= 5 THEN 'Weekend' ELSE 'Weekday' END [Day Type]
    , CONCAT(YEAR([Calendar].[Date]) / 10 * 10, 's') [Decade]
    , CASE
          WHEN MONTH([Calendar].[Date]) IN (12, 1, 2) THEN 'Winter'
          WHEN MONTH([Calendar].[Date]) IN (3, 4, 5) THEN 'Spring'
          WHEN MONTH([Calendar].[Date]) IN (6, 7, 8) THEN 'Summer'
          ELSE 'Fall'
      END [Season]
    , CASE
          WHEN MONTH([Calendar].[Date]) IN (12, 1, 2) THEN 1
          WHEN MONTH([Calendar].[Date]) IN (3, 4, 5) THEN 2
          WHEN MONTH([Calendar].[Date]) IN (6, 7, 8) THEN 3
          ELSE 4
      END [Season Number]
    , CAST ( CASE WHEN [Calendar].[Date] <= [LastReport].[LastReportedDate] THEN 1 ELSE 0 END AS BIT ) [Is Reported]
    , CASE
          WHEN [FactWeatherDaily].[PrecipitationIn] IS NULL THEN 'No Reading'
          WHEN [FactWeatherDaily].[PrecipitationIn] = 0 THEN 'Dry'
          WHEN [FactWeatherDaily].[PrecipitationIn] < 0.10 THEN 'Trace to 0.1 in'
          WHEN [FactWeatherDaily].[PrecipitationIn] < 0.50 THEN '0.1 to 0.5 in'
          ELSE '0.5 in or more'
      END [Precipitation Category]
    , CASE
          WHEN [FactWeatherDaily].[PrecipitationIn] IS NULL THEN 9
          WHEN [FactWeatherDaily].[PrecipitationIn] = 0 THEN 1
          WHEN [FactWeatherDaily].[PrecipitationIn] < 0.10 THEN 2
          WHEN [FactWeatherDaily].[PrecipitationIn] < 0.50 THEN 3
          ELSE 4
      END [Precipitation Category Number]
    , CASE
          WHEN [FactWeatherDaily].[TempMaxF] IS NULL THEN N'No Reading'
          WHEN [FactWeatherDaily].[TempMaxF] < 32 THEN N'Below 32°F'
          WHEN [FactWeatherDaily].[TempMaxF] < 60 THEN N'32 to 59°F'
          WHEN [FactWeatherDaily].[TempMaxF] < 75 THEN N'60 to 74°F'
          WHEN [FactWeatherDaily].[TempMaxF] < 90 THEN N'75 to 89°F'
          ELSE N'90°F and above'
      END [High Temperature Band]
    , CASE
          WHEN [FactWeatherDaily].[TempMaxF] IS NULL THEN 9
          WHEN [FactWeatherDaily].[TempMaxF] < 32 THEN 1
          WHEN [FactWeatherDaily].[TempMaxF] < 60 THEN 2
          WHEN [FactWeatherDaily].[TempMaxF] < 75 THEN 3
          WHEN [FactWeatherDaily].[TempMaxF] < 90 THEN 4
          ELSE 5
      END [High Temperature Band Number]
FROM
    [Calendar]
    CROSS JOIN [LastReport]
    LEFT JOIN [Warehouse].[FactWeatherDaily] ON [FactWeatherDaily].[StationID] = 'USW00094846'
        AND [FactWeatherDaily].[ObservationDate] = [Calendar].[Date]
        AND [Calendar].[Date] <= [LastReport].[LastReportedDate];
GO

CREATE OR ALTER VIEW [Analytics].[Station]
    AS
SELECT
    [DimStation].[StationCode] [Station Code]
    , [DimStation].[StationName] [Station Name]
    , CONCAT(UPPER(LEFT([DimStation].[District], 1)), LOWER(SUBSTRING([DimStation].[District], 2, 20))) [District]
FROM
    [Warehouse].[DimStation];
GO

/* [Ride Seconds] is total riding time, so average ride length can be weighted by trips in the model. */
CREATE OR ALTER VIEW [Analytics].[Station Activity]
    AS
SELECT
    [FactStationActivity].[ActivityDate] [Date]
    , [FactStationActivity].[StationCode] [Station Code]
    , [FactStationActivity].[TripsOut] [Trips Out]
    , [FactStationActivity].[TripsIn] [Trips In]
    , CAST ( ISNULL ( [FactStationActivity].[AverageRideSeconds], 0 ) AS BIGINT ) * [FactStationActivity].[TripsOut] [Ride Seconds]
    , [FactStationActivity].[Revenue]
FROM
    [Warehouse].[FactStationActivity];
GO

CREATE OR ALTER VIEW [Analytics].[Weather]
    AS
SELECT
    [FactWeatherDaily].[ObservationDate] [Date]
    , [FactWeatherDaily].[PrecipitationIn] [Precipitation In]
    , [FactWeatherDaily].[SnowfallIn] [Snowfall In]
    , [FactWeatherDaily].[SnowDepthIn] [Snow Depth In]
    , [FactWeatherDaily].[TempMaxF] [High Temp F]
    , [FactWeatherDaily].[TempMinF] [Low Temp F]
FROM
    [Warehouse].[FactWeatherDaily]
WHERE
    [FactWeatherDaily].[StationID] = 'USW00094846'
    AND [FactWeatherDaily].[ObservationDate] >= '1959-01-01'
    AND [FactWeatherDaily].[ObservationDate] <= ( SELECT MAX([FactStationActivity].[ActivityDate]) FROM [Warehouse].[FactStationActivity] );
GO
