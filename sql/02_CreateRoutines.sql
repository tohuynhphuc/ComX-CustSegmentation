/*
    CompanyX Customer Segmentation - 02_CreateRoutines.sql
    SQL Server programmable objects consolidated from:
      RFM_Live.sql (functions/procedures only)
      Cluster_RFM_StoredProcedures.sql
      Customer_Merge_Procedure.sql
      CustomerSnapshot_RFM_Backfill.sql (procedure only)

    RUN SECOND, after 01_CreateTables.sql and the operational CompanyX
    database are present. CREATE OR ALTER preserves saved warehouse data.

    This file deliberately excludes schema migration, historical backfill,
    one-time synchronization and demonstration EXEC statements.

    It retains original business logic for fidelity, including the existing
    incremental live refresh's purchase-date AsOfDate policy. See
    SETUP_FROM_SCRATCH.md / PROJECT_AUDIT.md before production deployment.
*/
USE [CompanyX_DataWarehouse];


GO
SET ANSI_NULLS ON;


GO
SET QUOTED_IDENTIFIER ON;


GO
-- ===========================================================================
-- Shared SQL RFM extraction (reads CompanyX transactions)
-- ===========================================================================
CREATE OR ALTER FUNCTION dbo.ufn_ComputeCustomerRFM
(@AsOfDate DATE)
RETURNS TABLE 
AS
RETURN 
    (SELECT   CONVERT (NVARCHAR (20), c.CustomerID) AS CustomerKey_Str,
              CAST (MAX(s.OrderDate) AS DATETIME2 (3)) AS LastPurchaseTimestamp,
              CAST (MAX(s.OrderDate) AS DATE) AS LastPurchaseDate,
              DATEDIFF(DAY, CAST (MAX(s.OrderDate) AS DATE), @AsOfDate) AS RecencyDays,
              COUNT(CASE WHEN s.OrderDate >= DATEADD(DAY, -364, @AsOfDate) THEN 1 END) AS Frequency365d,
              COALESCE (SUM(CASE WHEN s.OrderDate >= DATEADD(DAY, -364, @AsOfDate) THEN s.OrderAmount ELSE CAST (0 AS DECIMAL (19, 4)) END), CAST (0 AS DECIMAL (19, 4))) AS Monetary365d
     FROM     CompanyX.Sales.Customer AS c
              LEFT OUTER JOIN
              (SELECT   CONVERT (NVARCHAR (20), h.CustomerID) AS CustomerKey_Str,
                        h.SalesOrderID,
                        h.OrderDate,
                        SUM(CONVERT (DECIMAL (19, 4), d.LineTotal)) AS OrderAmount
               FROM     CompanyX.Sales.SalesOrderHeader AS h
                        INNER JOIN
                        CompanyX.Sales.SalesOrderDetail AS d
                        ON d.SalesOrderID = h.SalesOrderID
               WHERE    h.OrderDate < DATEADD(DAY, 1, @AsOfDate)
               -- TODO: Decide which SalesOrderHeader.Status values count as completed purchases.
               GROUP BY h.CustomerID, h.SalesOrderID, h.OrderDate) AS s
              ON s.CustomerKey_Str = CONVERT (NVARCHAR (20), c.CustomerID)
     GROUP BY c.CustomerID)



GO
-- ===========================================================================
-- Nearest-centroid SQL prediction
-- ===========================================================================
CREATE OR ALTER FUNCTION dbo.ufn_PredictRFMCluster
(@AsOfDate DATE, @RecencyDays INT, @Frequency365d INT, @Monetary365d DECIMAL (19, 4))
RETURNS TABLE 
AS
RETURN 
    (SELECT   TOP (1) m.ModelConfigKey,
                      m.ModelVersion,
                      m.ClusterSegment,
                      CONVERT (DECIMAL (18, 6), x.ScaledR) AS ScaledR,
                      CONVERT (DECIMAL (18, 6), x.ScaledF) AS ScaledF,
                      CONVERT (DECIMAL (18, 6), x.ScaledM) AS ScaledM
     FROM     dbo.DimModelConfig AS m CROSS APPLY (SELECT (LOG(1.0 + CONVERT (FLOAT, CASE WHEN @RecencyDays >= 0 THEN @RecencyDays ELSE 0 END)) - CONVERT (FLOAT, m.Mean_Scaled_R)) / NULLIF (CONVERT (FLOAT, m.Std_Scaled_R), 0.0) AS ScaledR,
                                                          (LOG(1.0 + CONVERT (FLOAT, CASE WHEN @Frequency365d >= 0 THEN @Frequency365d ELSE 0 END)) - CONVERT (FLOAT, m.Mean_Scaled_F)) / NULLIF (CONVERT (FLOAT, m.Std_Scaled_F), 0.0) AS ScaledF,
                                                          (LOG(1.0 + CONVERT (FLOAT, CASE WHEN @Monetary365d >= 0 THEN @Monetary365d ELSE 0 END)) - CONVERT (FLOAT, m.Mean_Scaled_M)) / NULLIF (CONVERT (FLOAT, m.Std_Scaled_M), 0.0) AS ScaledM) AS x
     WHERE    @AsOfDate IS NOT NULL
              AND @RecencyDays IS NOT NULL
              AND @Frequency365d IS NOT NULL
              AND @Monetary365d IS NOT NULL
              AND m.Std_Scaled_R > 0
              AND m.Std_Scaled_F > 0
              AND m.Std_Scaled_M > 0
              AND (@AsOfDate BETWEEN m.StartDate AND m.EndDate
                   OR (-- Explicit retrospective baseline; see header comment.
                   @AsOfDate >= CONVERT (DATE, '20110531', 112)
                   AND @AsOfDate < CONVERT (DATE, '20120101', 112)
                   AND m.StartDate = CONVERT (DATE, '20120101', 112)))
     ORDER BY POWER(x.ScaledR - CONVERT (FLOAT, m.Centroid_Scaled_R), 2) + POWER(x.ScaledF - CONVERT (FLOAT, m.Centroid_Scaled_F), 2) + POWER(x.ScaledM - CONVERT (FLOAT, m.Centroid_Scaled_M), 2), m.ClusterID)



GO
-- ===========================================================================
-- SCD0/1/2 staging customer MERGE
-- ===========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_ApplyCustomerProfileBatch
@BatchID UNIQUEIDENTIFIER, @EffectiveDate DATE=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ApplyDate AS DATE = COALESCE (@EffectiveDate, CONVERT (DATE, GETDATE()));
    IF @BatchID IS NULL
        BEGIN
            RAISERROR ('BatchID must be supplied.', 16, 1);
            RETURN;
        END
    IF NOT EXISTS (SELECT 1
                   FROM   stg.CustomerProfile
                   WHERE  BatchID = @BatchID)
        BEGIN
            RAISERROR ('No rows found in stg.CustomerProfile for the supplied BatchID.', 16, 1);
            RETURN;
        END
    -- Lock is held across the two MERGEs + history insertion.
    -- Intended for ONE SSIS merge run at a time.
    BEGIN TRY
        BEGIN TRANSACTION;
        -- Ensure only one customer merge procedure runs at a time.
        DECLARE @AppLockResult AS INT;
        EXECUTE @AppLockResult = sys.sp_getapplock @Resource = N'CompanyX_CustomerProfile_Merge', @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 15000;
        IF @AppLockResult < 0
            BEGIN
                RAISERROR ('Could not acquire exclusive customer-merge lock.', 16, 1);
            END
        /* Reject an already-corrupt history situation before modifying anything.
           If a changed historical row was inserted today, DATE resolution cannot
           represent a different SCD2 version on the same calendar day. */
        IF EXISTS (SELECT 1
                   FROM   stg.CustomerProfile AS s
                          INNER JOIN
                          dbo.DimClusterProfiling AS t WITH (UPDLOCK, HOLDLOCK)
                          ON t.CustomerKey_Str = s.CustomerKey_Str
                             AND t.IsCurrent = 1
                   WHERE  s.BatchID = @BatchID
                          AND t.StartDate >= @ApplyDate
                          AND EXISTS (SELECT s.YearlyIncome,
                                             s.Education,
                                             s.Occupation,
                                             s.CountryName,
                                             s.RegionGroup
                                      EXCEPT
                                      SELECT t.YearlyIncome,
                                             t.Education,
                                             t.Occupation,
                                             t.CountryName,
                                             t.RegionGroup))
            BEGIN
                RAISERROR ('A changed Type 2 row already starts on/after EffectiveDate. DATE-based history cannot represent this change; choose a later effective date or use DATETIME2-based history.', 16, 1);
            END
        /* A. Type 0 / Type 1.
           BirthDate is Type 0: inserted for new customer, never overwritten.
           Five Type 1 attributes are overwritten on change.
           EXCEPT is null-safe when comparing equivalent typed columns. */
        MERGE INTO dbo.DimCustomerProfiling WITH (HOLDLOCK)
         AS target
        USING (SELECT CustomerKey_Str,
                      BirthDate,
                      Gender,
                      MaritalStatus,
                      TotalChildren,
                      HomeOwnerFlag,
                      NumberCarsOwned
               FROM   stg.CustomerProfile
               WHERE  BatchID = @BatchID) AS source ON target.CustomerKey_Str = source.CustomerKey_Str
        WHEN MATCHED AND EXISTS (SELECT source.Gender,
                                        source.MaritalStatus,
                                        source.TotalChildren,
                                        source.HomeOwnerFlag,
                                        source.NumberCarsOwned
                                 EXCEPT
                                 SELECT target.Gender,
                                        target.MaritalStatus,
                                        target.TotalChildren,
                                        target.HomeOwnerFlag,
                                        target.NumberCarsOwned) THEN UPDATE 
        SET Gender          = source.Gender,
            MaritalStatus   = source.MaritalStatus,
            TotalChildren   = source.TotalChildren,
            HomeOwnerFlag   = source.HomeOwnerFlag,
            NumberCarsOwned = source.NumberCarsOwned
        WHEN NOT MATCHED BY TARGET THEN INSERT (CustomerKey_Str, BirthDate, Gender, MaritalStatus, TotalChildren, HomeOwnerFlag, NumberCarsOwned) VALUES (source.CustomerKey_Str, source.BirthDate, source.Gender, source.MaritalStatus, source.TotalChildren, source.HomeOwnerFlag, source.NumberCarsOwned);
        /* B. Type 2.
           - New business key => insert current version.
           - Changed key => expire current version and record the key in
             @ClusterActions; follow with a separate INSERT of its new version.
           - Unchanged => do nothing.
           - No WHEN NOT MATCHED BY SOURCE: partial staging batches must not
             implicitly retire absent customers.
        */
        DECLARE @ClusterActions TABLE (
            ActionName      NVARCHAR (10) NOT NULL,
            CustomerKey_Str NVARCHAR (20) NOT NULL);
        MERGE INTO dbo.DimClusterProfiling WITH (HOLDLOCK)
         AS target
        USING (SELECT CustomerKey_Str,
                      YearlyIncome,
                      Education,
                      Occupation,
                      CountryName,
                      RegionGroup
               FROM   stg.CustomerProfile
               WHERE  BatchID = @BatchID) AS source ON target.CustomerKey_Str = source.CustomerKey_Str
                                                       AND target.IsCurrent = 1
        WHEN MATCHED AND EXISTS (SELECT source.YearlyIncome,
                                        source.Education,
                                        source.Occupation,
                                        source.CountryName,
                                        source.RegionGroup
                                 EXCEPT
                                 SELECT target.YearlyIncome,
                                        target.Education,
                                        target.Occupation,
                                        target.CountryName,
                                        target.RegionGroup) THEN UPDATE 
        SET IsCurrent = 0,
            EndDate   = DATEADD(DAY, -1, @ApplyDate)
        WHEN NOT MATCHED BY TARGET THEN INSERT (CustomerKey_Str, YearlyIncome, Education, Occupation, CountryName, RegionGroup, StartDate, EndDate, IsCurrent) VALUES (source.CustomerKey_Str, source.YearlyIncome, source.Education, source.Occupation, source.CountryName, source.RegionGroup, @ApplyDate, CONVERT (DATE, '99991231', 112), 1)
        OUTPUT $ACTION, inserted.CustomerKey_Str INTO @ClusterActions (ActionName, CustomerKey_Str);
        /* C. Add replacement rows for those old versions just expired. */
        INSERT dbo.DimClusterProfiling (CustomerKey_Str, YearlyIncome, Education, Occupation, CountryName, RegionGroup, StartDate, EndDate, IsCurrent)
        SELECT s.CustomerKey_Str,
               s.YearlyIncome,
               s.Education,
               s.Occupation,
               s.CountryName,
               s.RegionGroup,
               @ApplyDate,
               CONVERT (DATE, '99991231', 112),
               1
        FROM   stg.CustomerProfile AS s
               INNER JOIN
               @ClusterActions AS a
               ON a.CustomerKey_Str = s.CustomerKey_Str
                  AND a.ActionName = N'UPDATE'
        WHERE  s.BatchID = @BatchID;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK;
        DECLARE @ErrorMessage AS NVARCHAR (4000) = ERROR_MESSAGE();
        RAISERROR (N'Customer MERGE failed: %s', 16, 1, @ErrorMessage);
        RETURN;
    END CATCH
END


GO
-- ===========================================================================
-- Current/live customer RFM refresh
-- ===========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCustomerRFMLive
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Cutoff AS DATETIME = GETDATE(); -- extraction clock, NOT purchase date
    DECLARE @LastWatermark AS DATETIME;
    DECLARE @LockResult AS INT;
    DECLARE @ChangedRows AS INT = 0;
    BEGIN TRY
        BEGIN TRANSACTION;
        -- Prevent overlapping SQL Agent executions from processing the same window.
        EXECUTE @LockResult = sys.sp_getapplock @Resource = N'CompanyX_RFM_Live_Refresh', @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 60000;
        IF @LockResult < 0
            THROW 51121, 'Could not acquire RFM Live refresh lock.', 1;
        IF NOT EXISTS (SELECT 1
                       FROM   dbo.ETL_Watermark WITH (UPDLOCK, HOLDLOCK)
                       WHERE  PipelineName = 'RFM_Live')
            BEGIN
                -- First run will initialize customers from historical source orders.
                INSERT  dbo.ETL_Watermark (PipelineName, LastWatermark)
                VALUES                   ('RFM_Live', CONVERT (DATETIME, '19000101', 112));
            END
        SELECT @LastWatermark = LastWatermark
        FROM   dbo.ETL_Watermark WITH (UPDLOCK, HOLDLOCK)
        WHERE  PipelineName = 'RFM_Live';
        CREATE TABLE #AffectedCustomers (
            CustomerID INT NOT NULL PRIMARY KEY
        );
        -- Both header and detail modifications can affect a customer's RFM.
        -- Inclusive lower / exclusive upper bound avoids missing equal timestamps.
        INSERT #AffectedCustomers (CustomerID)
        SELECT CustomerID
        FROM   (SELECT h.CustomerID
                FROM   CompanyX.Sales.SalesOrderHeader AS h
                WHERE  h.ModifiedDate >= @LastWatermark
                       AND h.ModifiedDate < @Cutoff
                UNION
                SELECT h.CustomerID
                FROM   CompanyX.Sales.SalesOrderDetail AS d
                       INNER JOIN
                       CompanyX.Sales.SalesOrderHeader AS h
                       ON h.SalesOrderID = d.SalesOrderID
                WHERE  d.ModifiedDate >= @LastWatermark
                       AND d.ModifiedDate < @Cutoff) AS ChangedSales; -- Recalculate full purchase history ONLY for affected customers,
         -- evaluated at each customer's latest purchase date.
        WITH CustomerOrders
        AS   (SELECT   h.CustomerID,
                       h.SalesOrderID,
                       h.OrderDate,
                       SUM(CONVERT (DECIMAL (19, 4), d.LineTotal)) AS OrderAmount
              FROM     #AffectedCustomers AS a
                       INNER JOIN
                       CompanyX.Sales.SalesOrderHeader AS h
                       ON h.CustomerID = a.CustomerID
                       INNER JOIN
                       CompanyX.Sales.SalesOrderDetail AS d
                       ON d.SalesOrderID = h.SalesOrderID
              GROUP BY h.CustomerID, h.SalesOrderID, h.OrderDate),
             LatestPurchase
        AS   (SELECT   CustomerID,
                       MAX(OrderDate) AS LastOrderTimestamp
              FROM     CustomerOrders
              GROUP BY CustomerID),
             CustomerRFM
        AS   (SELECT   CONVERT (NVARCHAR (20), o.CustomerID) AS CustomerKey_Str,
                       CONVERT (DATE, l.LastOrderTimestamp) AS AsOfDate,
                       CONVERT (DATETIME2 (3), l.LastOrderTimestamp) AS LastPurchaseTimestamp,
                       CONVERT (DATE, l.LastOrderTimestamp) AS LastPurchaseDate,
                       CAST (0 AS INT) AS RecencyDays,
                       COUNT(CASE WHEN o.OrderDate >= DATEADD(DAY, -364, CONVERT (DATE, l.LastOrderTimestamp)) THEN 1 END) AS Frequency365d,
                       COALESCE (SUM(CASE WHEN o.OrderDate >= DATEADD(DAY, -364, CONVERT (DATE, l.LastOrderTimestamp)) THEN o.OrderAmount ELSE CONVERT (DECIMAL (19, 4), 0) END), CONVERT (DECIMAL (19, 4), 0)) AS Monetary365d
              FROM     CustomerOrders AS o
                       INNER JOIN
                       LatestPurchase AS l
                       ON l.CustomerID = o.CustomerID
              GROUP BY o.CustomerID, l.LastOrderTimestamp)
        MERGE INTO dbo.FactCustomerRFMLive WITH (HOLDLOCK)
         AS target
        USING (SELECT r.*,
                      p.ClusterProfilingSK
               FROM   CustomerRFM AS r
                      INNER JOIN
                      dbo.DimCustomerProfiling AS dc
                      ON dc.CustomerKey_Str = r.CustomerKey_Str
                      LEFT OUTER JOIN
                      dbo.DimClusterProfiling AS p
                      ON p.CustomerKey_Str = r.CustomerKey_Str
                         AND p.IsCurrent = 1) AS source ON source.CustomerKey_Str = target.CustomerKey_Str
        WHEN MATCHED AND EXISTS (SELECT source.AsOfDate,
                                        source.LastPurchaseDate,
                                        source.LastPurchaseTimestamp,
                                        source.RecencyDays,
                                        source.Frequency365d,
                                        source.Monetary365d,
                                        source.ClusterProfilingSK
                                 EXCEPT
                                 SELECT target.AsOfDate,
                                        target.LastPurchaseDate,
                                        target.LastPurchaseTimestamp,
                                        target.RecencyDays,
                                        target.Frequency365d,
                                        target.Monetary365d,
                                        target.ClusterProfilingSK) THEN UPDATE 
        SET target.AsOfDate              = source.AsOfDate,
            target.LastPurchaseDate      = source.LastPurchaseDate,
            target.LastPurchaseTimestamp = source.LastPurchaseTimestamp,
            target.RecencyDays           = source.RecencyDays,
            target.Frequency365d         = source.Frequency365d,
            target.Monetary365d          = source.Monetary365d,
            target.ClusterProfilingSK    = source.ClusterProfilingSK,
            target.ModelConfigKey        = NULL,
            target.ClusterSegment        = NULL,
            target.UpdatedAtUtc          = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT (CustomerKey_Str, AsOfDate, LastPurchaseDate, LastPurchaseTimestamp, RecencyDays, Frequency365d, Monetary365d, ClusterProfilingSK, ModelConfigKey, ClusterSegment) VALUES (source.CustomerKey_Str, source.AsOfDate, source.LastPurchaseDate, source.LastPurchaseTimestamp, source.RecencyDays, source.Frequency365d, source.Monetary365d, source.ClusterProfilingSK, NULL, NULL);
        SET @ChangedRows = @@ROWCOUNT;
        -- Advance watermark in the SAME transaction as the RFM changes.
        UPDATE dbo.ETL_Watermark
        SET    LastWatermark = @Cutoff
        WHERE  PipelineName = 'RFM_Live';
        COMMIT TRANSACTION;
        PRINT CONCAT('RFM Live inserted/updated rows: ', @ChangedRows, '; processed through ', CONVERT (VARCHAR (23), @Cutoff, 121));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;
        THROW;
    END CATCH
END


GO
-- ===========================================================================
-- Idempotent monthly RFM snapshot append
-- ===========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_AppendMonthlyRFMSnapshot
@SnapshotDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @SnapshotDate IS NULL
       OR @SnapshotDate <> EOMONTH(@SnapshotDate)
        THROW 51104, 'SnapshotDate must be a month-end date.', 1;
    DECLARE @SnapshotMonth AS DATE = DATEFROMPARTS(YEAR(@SnapshotDate), MONTH(@SnapshotDate), 1);
    DECLARE @SnapshotDateKey AS INT = CONVERT (INT, CONVERT (CHAR (8), @SnapshotDate, 112));
    IF NOT EXISTS (SELECT 1
                   FROM   dbo.DimDate
                   WHERE  DateKey = @SnapshotDateKey)
        THROW 51105, 'Snapshot date is missing from DimDate.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @LockResult AS INT;
        EXECUTE @LockResult = sys.sp_getapplock @Resource = 'CompanyX_Monthly_Customer_RFM_Snapshot', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @LockResult < 0
            THROW 51106, 'Could not acquire snapshot lock.', 1;
        -- Stage only customers for whom this month is not yet present.
        -- Resolve the SCD2 surrogate key before making any insert.
        SELECT r.CustomerKey_Str,
               r.LastPurchaseDate,
               r.RecencyDays,
               r.Frequency365d,
               r.Monetary365d,
               CASE WHEN history_at_date.ClusterProfilingSK IS NOT NULL THEN history_at_date.ClusterProfilingSK WHEN earliest_profile.StartDate > @SnapshotDate THEN earliest_profile.ClusterProfilingSK ELSE NULL END AS ClusterProfilingSK
        INTO   #NewSnapshotRows
        FROM   dbo.ufn_ComputeCustomerRFM(@SnapshotDate) AS r
               INNER JOIN
               dbo.DimCustomerProfiling AS dc
               ON dc.CustomerKey_Str = r.CustomerKey_Str OUTER APPLY (SELECT   TOP (1) p.ClusterProfilingSK
                                                                      FROM     dbo.DimClusterProfiling AS p
                                                                      WHERE    p.CustomerKey_Str = r.CustomerKey_Str
                                                                               AND p.StartDate <= @SnapshotDate
                                                                               AND p.EndDate >= @SnapshotDate
                                                                      ORDER BY p.StartDate DESC, p.ClusterProfilingSK DESC) AS history_at_date OUTER APPLY (SELECT   TOP (1) p.ClusterProfilingSK,
                                                                                                                                                                             p.StartDate
                                                                                                                                                            FROM     dbo.DimClusterProfiling AS p
                                                                                                                                                            WHERE    p.CustomerKey_Str = r.CustomerKey_Str
                                                                                                                                                            ORDER BY p.StartDate ASC, p.ClusterProfilingSK ASC) AS earliest_profile
        WHERE  r.LastPurchaseDate IS NOT NULL
               AND NOT EXISTS (SELECT 1
                               FROM   dbo.FactCustomerSnapshot AS s WITH (UPDLOCK, HOLDLOCK)
                               WHERE  s.CustomerKey_Str = r.CustomerKey_Str
                                      AND s.SnapshotMonth = @SnapshotMonth);
        -- Do not silently omit eligible customers or leave their SK blank.
        IF EXISTS (SELECT 1
                   FROM   #NewSnapshotRows
                   WHERE  ClusterProfilingSK IS NULL)
            THROW 51107, 'Some snapshot customers have no usable DimClusterProfiling version. Load/repair customer profiles first.', 1;
        INSERT INTO dbo.FactCustomerSnapshot (CustomerKey_Str, SnapshotMonth, SnapshotDateKey, ModelConfigKey, ClusterProfilingSK, ClusterSegment, LastPurchaseDate, RecencyDays, Frequency365d, Monetary365d, ScaledR, ScaledF, ScaledM)
        SELECT r.CustomerKey_Str,
               @SnapshotMonth,
               @SnapshotDateKey,
               NULL,
               r.ClusterProfilingSK,
               NULL,
               r.LastPurchaseDate,
               r.RecencyDays,
               r.Frequency365d,
               r.Monetary365d,
               NULL,
               NULL,
               NULL
        FROM   #NewSnapshotRows AS r;
        DECLARE @RowsInserted AS INT = @@ROWCOUNT;
        COMMIT TRANSACTION;
        SELECT @SnapshotDate AS SnapshotDate,
               @RowsInserted AS RowsInserted,
               (SELECT COUNT(*)
                FROM   dbo.FactCustomerSnapshot
                WHERE  SnapshotMonth = @SnapshotMonth) AS TotalRowsForMonth;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK;
        THROW;
    END CATCH
END


GO
-- ===========================================================================
-- Model completeness validation
-- ===========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_ValidateRFMModels
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT   1
               FROM     dbo.DimModelConfig
               GROUP BY ModelVersion
               HAVING   COUNT(*) <> 5
                        OR COUNT(DISTINCT ClusterID) <> 5
                        OR COUNT(DISTINCT StartDate) <> 1
                        OR COUNT(DISTINCT EndDate) <> 1
                        OR MIN(Std_Scaled_R) <= 0
                        OR MIN(Std_Scaled_F) <= 0
                        OR MIN(Std_Scaled_M) <= 0)
        THROW 51200, 'Incomplete/inconsistent RFM model: expected five clusters and one effective interval per version, with positive scaler standard deviations.', 1;
END


GO
-- ===========================================================================
-- Classify live RFM customers using persisted model
-- ===========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_ClusterCustomerRFMLive
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @LockResult AS INT;
    BEGIN TRY
        BEGIN TRANSACTION;
        -- Same application lock as usp_RefreshCustomerRFMLive to avoid
        -- scoring old RFM values while the refresh is updating them.
        EXECUTE @LockResult = sys.sp_getapplock @Resource = N'CompanyX_RFM_Live_Refresh', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 60000;
        IF @LockResult < 0
            THROW 51201, 'Cannot acquire Live RFM scoring lock.', 1;
        EXECUTE dbo.usp_ValidateRFMModels ;
        -- Per-customer AsOfDate; NEVER select one global model for the Live table.
        -- Fail instead of silently assigning the wrong model or dropping rows.
        IF EXISTS (SELECT 1
                   FROM   (SELECT DISTINCT AsOfDate
                           FROM   dbo.FactCustomerRFMLive
                           WHERE  (ModelConfigKey IS NULL
                                   OR ClusterSegment IS NULL)
                                  AND RecencyDays IS NOT NULL) AS dates_to_score OUTER APPLY (SELECT COUNT(DISTINCT m.ModelVersion) AS NumberOfVersions
                                                                                              FROM   dbo.DimModelConfig AS m
                                                                                              WHERE  dates_to_score.AsOfDate BETWEEN m.StartDate AND m.EndDate
                                                                                                     OR (dates_to_score.AsOfDate >= CONVERT (DATE, '20110531', 112)
                                                                                                         AND dates_to_score.AsOfDate < CONVERT (DATE, '20120101', 112)
                                                                                                         AND m.StartDate = CONVERT (DATE, '20120101', 112))) AS model_check
                   WHERE  model_check.NumberOfVersions <> 1)
            THROW 51202, 'Live rows have no effective model or multiple overlapping models. Check DimModelConfig dates.', 1;
        UPDATE l
        SET    l.ModelConfigKey = prediction.ModelConfigKey,
               l.ClusterSegment = prediction.ClusterSegment,
               l.UpdatedAtUtc   = SYSUTCDATETIME()
        FROM   dbo.FactCustomerRFMLive AS l CROSS APPLY dbo.ufn_PredictRFMCluster(l.AsOfDate, l.RecencyDays, l.Frequency365d, l.Monetary365d) AS prediction
        WHERE  (l.ModelConfigKey IS NULL
                OR l.ClusterSegment IS NULL)
               AND l.RecencyDays IS NOT NULL;
        DECLARE @RowsScored AS INT = @@ROWCOUNT;
        COMMIT TRANSACTION;
        PRINT CONCAT('Live RFM customers classified: ', @RowsScored);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;
        THROW;
    END CATCH
END


GO
-- ===========================================================================
-- Classify unscored monthly snapshots using persisted model
-- ===========================================================================
CREATE OR ALTER PROCEDURE dbo.usp_ClusterCustomerRFMSnapshot
@SnapshotDate DATE=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @SnapshotDate IS NOT NULL
       AND @SnapshotDate <> EOMONTH(@SnapshotDate)
        THROW 51210, 'SnapshotDate must be month-end.', 1;
    DECLARE @SnapshotDateKey AS INT = CASE WHEN @SnapshotDate IS NULL THEN NULL ELSE CONVERT (INT, CONVERT (CHAR (8), @SnapshotDate, 112)) END;
    DECLARE @LockResult AS INT;
    BEGIN TRY
        BEGIN TRANSACTION;
        -- Same application lock as the monthly snapshot insert procedure.
        EXECUTE @LockResult = sys.sp_getapplock @Resource = N'CompanyX_Monthly_Customer_RFM_Snapshot', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 60000;
        IF @LockResult < 0
            THROW 51211, 'Cannot acquire monthly snapshot scoring lock.', 1;
        EXECUTE dbo.usp_ValidateRFMModels ;
        IF EXISTS (SELECT 1
                   FROM   (SELECT DISTINCT SnapshotDateKey
                           FROM   dbo.FactCustomerSnapshot
                           WHERE  (@SnapshotDateKey IS NULL
                                   OR SnapshotDateKey = @SnapshotDateKey)
                                  AND (ModelConfigKey IS NULL
                                       OR ClusterSegment IS NULL)
                                  AND RecencyDays IS NOT NULL) AS dates_to_score OUTER APPLY (SELECT COUNT(DISTINCT m.ModelVersion) AS NumberOfVersions
                                                                                              FROM   dbo.DimModelConfig AS m
                                                                                              WHERE  CONVERT (DATE, CONVERT (CHAR (8), dates_to_score.SnapshotDateKey), 112) BETWEEN m.StartDate AND m.EndDate
                                                                                                     OR (dates_to_score.SnapshotDateKey >= 20110531
                                                                                                         AND dates_to_score.SnapshotDateKey < 20120101
                                                                                                         AND m.StartDate = CONVERT (DATE, '20120101', 112))) AS model_check
                   WHERE  model_check.NumberOfVersions <> 1)
            THROW 51212, 'Snapshot rows have no effective model or multiple overlapping models. Check DimModelConfig dates.', 1;
        UPDATE s
        SET    s.ModelConfigKey = prediction.ModelConfigKey,
               s.ClusterSegment = prediction.ClusterSegment,
               s.ScaledR        = prediction.ScaledR,
               s.ScaledF        = prediction.ScaledF,
               s.ScaledM        = prediction.ScaledM
        FROM   dbo.FactCustomerSnapshot AS s CROSS APPLY dbo.ufn_PredictRFMCluster(CONVERT (DATE, CONVERT (CHAR (8), s.SnapshotDateKey), 112), s.RecencyDays, s.Frequency365d, s.Monetary365d) AS prediction
        WHERE  (@SnapshotDateKey IS NULL
                OR s.SnapshotDateKey = @SnapshotDateKey)
               AND (s.ModelConfigKey IS NULL
                    OR s.ClusterSegment IS NULL)
               AND s.RecencyDays IS NOT NULL;
        DECLARE @RowsScored AS INT = @@ROWCOUNT;
        COMMIT TRANSACTION;
        PRINT CONCAT('Snapshot RFM rows classified: ', @RowsScored);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;
        THROW;
    END CATCH
END


GO
/* Verification - expect six procedures and two functions. */
SELECT   OBJECT_SCHEMA_NAME(o.object_id) AS SchemaName,
         o.name AS ObjectName,
         o.type_desc AS ObjectType
FROM     sys.objects AS o
WHERE    o.schema_id = SCHEMA_ID(N'dbo')
         AND o.name IN (N'ufn_ComputeCustomerRFM', N'ufn_PredictRFMCluster', N'usp_ApplyCustomerProfileBatch', N'usp_RefreshCustomerRFMLive', N'usp_AppendMonthlyRFMSnapshot', N'usp_ValidateRFMModels', N'usp_ClusterCustomerRFMLive', N'usp_ClusterCustomerRFMSnapshot')
ORDER BY ObjectType, ObjectName;
