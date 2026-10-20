USE [CompanyX_DataWarehouse];
GO


CREATE OR ALTER FUNCTION dbo.ufn_PredictRFMCluster
(
    @AsOfDate DATE,
    @RecencyDays INT,
    @Frequency365d INT,
    @Monetary365d DECIMAL(19,4)
)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (1)
        m.ModelConfigKey,
        m.ModelVersion,
        m.ClusterSegment,
        CONVERT(DECIMAL(18,6), x.ScaledR) AS ScaledR,
        CONVERT(DECIMAL(18,6), x.ScaledF) AS ScaledF,
        CONVERT(DECIMAL(18,6), x.ScaledM) AS ScaledM
    FROM dbo.DimModelConfig AS m
    CROSS APPLY
    (
        SELECT
            (LOG(1.0 + CONVERT(FLOAT,
                        CASE WHEN @RecencyDays >= 0 THEN @RecencyDays ELSE 0 END))
                - CONVERT(FLOAT, m.Mean_Scaled_R))
                  / NULLIF(CONVERT(FLOAT, m.Std_Scaled_R), 0.0) AS ScaledR,
            (LOG(1.0 + CONVERT(FLOAT,
                        CASE WHEN @Frequency365d >= 0 THEN @Frequency365d ELSE 0 END))
                - CONVERT(FLOAT, m.Mean_Scaled_F))
                  / NULLIF(CONVERT(FLOAT, m.Std_Scaled_F), 0.0) AS ScaledF,
            (LOG(1.0 + CONVERT(FLOAT,
                        CASE WHEN @Monetary365d >= 0 THEN @Monetary365d ELSE 0 END))
                - CONVERT(FLOAT, m.Mean_Scaled_M))
                  / NULLIF(CONVERT(FLOAT, m.Std_Scaled_M), 0.0) AS ScaledM
    ) AS x
    WHERE @AsOfDate IS NOT NULL
      AND @RecencyDays IS NOT NULL
      AND @Frequency365d IS NOT NULL
      AND @Monetary365d IS NOT NULL
      AND m.Std_Scaled_R > 0
      AND m.Std_Scaled_F > 0
      AND m.Std_Scaled_M > 0
      AND
      (
          @AsOfDate BETWEEN m.StartDate AND m.EndDate
          OR
          (
              -- Explicit retrospective baseline; see header comment.
              @AsOfDate >= CONVERT(DATE, '20110531', 112)
              AND @AsOfDate < CONVERT(DATE, '20120101', 112)
              AND m.StartDate = CONVERT(DATE, '20120101', 112)
          )
      )
    ORDER BY
        POWER(x.ScaledR - CONVERT(FLOAT, m.Centroid_Scaled_R), 2)
      + POWER(x.ScaledF - CONVERT(FLOAT, m.Centroid_Scaled_F), 2)
      + POWER(x.ScaledM - CONVERT(FLOAT, m.Centroid_Scaled_M), 2),
        m.ClusterID
);
GO

-- Validate that saved model versions are complete and internally consistent.
-- Historical versions can have IsActive=0: that MUST NOT exclude them from prediction.
CREATE OR ALTER PROCEDURE dbo.usp_ValidateRFMModels
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS
    (
        SELECT 1
        FROM dbo.DimModelConfig
        GROUP BY ModelVersion
        HAVING COUNT(*) <> 5
            OR COUNT(DISTINCT ClusterID) <> 5
            OR COUNT(DISTINCT StartDate) <> 1
            OR COUNT(DISTINCT EndDate) <> 1
            OR MIN(Std_Scaled_R) <= 0
            OR MIN(Std_Scaled_F) <= 0
            OR MIN(Std_Scaled_M) <= 0
    )
        THROW 51200, 'Incomplete/inconsistent RFM model: expected five clusters and one effective interval per version, with positive scaler standard deviations.', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ClusterCustomerRFMLive
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LockResult INT;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Same application lock as usp_RefreshCustomerRFMLive to avoid
        -- scoring old RFM values while the refresh is updating them.
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'CompanyX_RFM_Live_Refresh',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 60000;
        IF @LockResult < 0
            THROW 51201, 'Cannot acquire Live RFM scoring lock.', 1;

        EXEC dbo.usp_ValidateRFMModels;

        -- Per-customer AsOfDate; NEVER select one global model for the Live table.
        -- Fail instead of silently assigning the wrong model or dropping rows.
        IF EXISTS
        (
            SELECT 1
            FROM
            (
                SELECT DISTINCT AsOfDate
                FROM dbo.FactCustomerRFMLive
                WHERE (ModelConfigKey IS NULL OR ClusterSegment IS NULL)
                  AND RecencyDays IS NOT NULL
            ) AS dates_to_score
            OUTER APPLY
            (
                SELECT COUNT(DISTINCT m.ModelVersion) AS NumberOfVersions
                FROM dbo.DimModelConfig AS m
                WHERE dates_to_score.AsOfDate BETWEEN m.StartDate AND m.EndDate
                    OR (
                        dates_to_score.AsOfDate >= CONVERT(DATE, '20110531', 112)
                        AND dates_to_score.AsOfDate < CONVERT(DATE, '20120101', 112)
                        AND m.StartDate = CONVERT(DATE, '20120101', 112)
                    )
            ) AS model_check
            WHERE model_check.NumberOfVersions <> 1
        )
            THROW 51202, 'Live rows have no effective model or multiple overlapping models. Check DimModelConfig dates.', 1;

        UPDATE l
        SET l.ModelConfigKey = prediction.ModelConfigKey,
            l.ClusterSegment = prediction.ClusterSegment,
            l.UpdatedAtUtc = SYSUTCDATETIME()
        FROM dbo.FactCustomerRFMLive AS l
        CROSS APPLY dbo.ufn_PredictRFMCluster(
            l.AsOfDate,
            l.RecencyDays,
            l.Frequency365d,
            l.Monetary365d
        ) AS prediction
        WHERE (l.ModelConfigKey IS NULL OR l.ClusterSegment IS NULL)
          AND l.RecencyDays IS NOT NULL;

        DECLARE @RowsScored INT = @@ROWCOUNT;
        COMMIT TRANSACTION;
        PRINT CONCAT('Live RFM customers classified: ', @RowsScored);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- @SnapshotDate=NULL scores EVERY historical month still missing labels.
-- In the monthly scheduled job, this also picks up the new month only,
-- once the backlog has been completed. Run manually after publishing models
-- to classify 2012, 2013 and 2014 historical snapshots in one go.
CREATE OR ALTER PROCEDURE dbo.usp_ClusterCustomerRFMSnapshot
    @SnapshotDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @SnapshotDate IS NOT NULL AND @SnapshotDate <> EOMONTH(@SnapshotDate)
        THROW 51210, 'SnapshotDate must be month-end.', 1;

    DECLARE @SnapshotDateKey INT =
        CASE WHEN @SnapshotDate IS NULL THEN NULL
             ELSE CONVERT(INT, CONVERT(CHAR(8), @SnapshotDate, 112)) END;
    DECLARE @LockResult INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Same application lock as the monthly snapshot insert procedure.
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'CompanyX_Monthly_Customer_RFM_Snapshot',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 60000;
        IF @LockResult < 0
            THROW 51211, 'Cannot acquire monthly snapshot scoring lock.', 1;

        EXEC dbo.usp_ValidateRFMModels;

        IF EXISTS
        (
            SELECT 1
            FROM
            (
                SELECT DISTINCT SnapshotDateKey
                FROM dbo.FactCustomerSnapshot
                WHERE (@SnapshotDateKey IS NULL OR SnapshotDateKey = @SnapshotDateKey)
                  AND (ModelConfigKey IS NULL OR ClusterSegment IS NULL)
                  AND RecencyDays IS NOT NULL
            ) AS dates_to_score
            OUTER APPLY
            (
                SELECT COUNT(DISTINCT m.ModelVersion) AS NumberOfVersions
                FROM dbo.DimModelConfig AS m
                WHERE CONVERT(DATE, CONVERT(CHAR(8), dates_to_score.SnapshotDateKey), 112)
                      BETWEEN m.StartDate AND m.EndDate
                    OR (
                        dates_to_score.SnapshotDateKey >= 20110531
                        AND dates_to_score.SnapshotDateKey < 20120101
                        AND m.StartDate = CONVERT(DATE, '20120101', 112)
                    )
            ) AS model_check
            WHERE model_check.NumberOfVersions <> 1
        )
            THROW 51212, 'Snapshot rows have no effective model or multiple overlapping models. Check DimModelConfig dates.', 1;

        UPDATE s
        SET s.ModelConfigKey = prediction.ModelConfigKey,
            s.ClusterSegment = prediction.ClusterSegment,
            s.ScaledR = prediction.ScaledR,
            s.ScaledF = prediction.ScaledF,
            s.ScaledM = prediction.ScaledM
        FROM dbo.FactCustomerSnapshot AS s
        CROSS APPLY dbo.ufn_PredictRFMCluster(
            CONVERT(DATE, CONVERT(CHAR(8), s.SnapshotDateKey), 112),
            s.RecencyDays,
            s.Frequency365d,
            s.Monetary365d
        ) AS prediction
        WHERE (@SnapshotDateKey IS NULL OR s.SnapshotDateKey = @SnapshotDateKey)
          AND (s.ModelConfigKey IS NULL OR s.ClusterSegment IS NULL)
          AND s.RecencyDays IS NOT NULL;

        DECLARE @RowsScored INT = @@ROWCOUNT;
        COMMIT TRANSACTION;
        PRINT CONCAT('Snapshot RFM rows classified: ', @RowsScored);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/*
-- One-time historical catch-up after annual models have been published:
EXEC dbo.usp_ClusterCustomerRFMSnapshot;
EXEC dbo.usp_ClusterCustomerRFMLive;

-- Inspect assignments and model versions:
SELECT s.SnapshotDateKey, m.ModelVersion, COUNT(*) AS Customers
FROM dbo.FactCustomerSnapshot s
LEFT JOIN dbo.DimModelConfig m ON m.ModelConfigKey = s.ModelConfigKey
GROUP BY s.SnapshotDateKey, m.ModelVersion
ORDER BY s.SnapshotDateKey, m.ModelVersion;

SELECT YEAR(l.AsOfDate) AS RFMYear, m.ModelVersion, COUNT(*) AS Customers
FROM dbo.FactCustomerRFMLive l
LEFT JOIN dbo.DimModelConfig m ON m.ModelConfigKey = l.ModelConfigKey
GROUP BY YEAR(l.AsOfDate), m.ModelVersion
ORDER BY RFMYear, m.ModelVersion;
*/
