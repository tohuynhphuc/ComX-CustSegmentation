/*
 CompanyX Data Warehouse -- Refined Diagram: RFM milestone
 SQL Server 2016 SP1+ recommended (CREATE OR ALTER).

 NON-DESTRUCTIVE: Does not drop warehouse tables or truncate data. No FactSales/DimProduct dependency.
 Assumes CompanyX and CompanyX_DataWarehouse are on the SAME SQL Server instance.
 Assumes these tables ALREADY exist:
   dbo.DimCustomerProfiling, dbo.DimClusterProfiling, dbo.DimModelConfig,
   dbo.FactCustomerRFMLive, dbo.FactCustomerSnapshot, dbo.DimDate

 Existing names kept: CustomerKey_Str, ClusterProfilingSK,
 RecencyDays, Frequency365d, Monetary365d, SnapshotDateKey.
 Frequencies/amounts use ROLLING 365 DAYS; Recency is days since last
 EVER purchase on or before the evaluation date. Decide window policy with team.
 Current illustrative data end: 2014-06-30; avoid @AsOfDate=GETDATE()
 when making an historical 2014 demonstration.
*/
USE [CompanyX_DataWarehouse];
GO
SET NOCOUNT ON;
GO

-- 1. Align live RFM with refined diagram without destroying existing rows.
IF COL_LENGTH('dbo.FactCustomerRFMLive', 'ClusterProfilingSK') IS NULL
    ALTER TABLE dbo.FactCustomerRFMLive ADD ClusterProfilingSK INT NULL;
IF COL_LENGTH('dbo.FactCustomerRFMLive', 'ModelConfigKey') IS NULL
    ALTER TABLE dbo.FactCustomerRFMLive ADD ModelConfigKey INT NULL;
IF COL_LENGTH('dbo.FactCustomerRFMLive', 'ClusterSegment') IS NULL
    ALTER TABLE dbo.FactCustomerRFMLive ADD ClusterSegment NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.FactCustomerRFMLive', 'LastPurchaseTimestamp') IS NULL
    ALTER TABLE dbo.FactCustomerRFMLive ADD LastPurchaseTimestamp DATETIME2(3) NULL;
GO

-- 2. Align monthly snapshots with refined diagram.
IF COL_LENGTH('dbo.FactCustomerSnapshot', 'ClusterProfilingSK') IS NULL
    ALTER TABLE dbo.FactCustomerSnapshot ADD ClusterProfilingSK INT NULL;
IF COL_LENGTH('dbo.FactCustomerSnapshot', 'ClusterSegment') IS NULL
    ALTER TABLE dbo.FactCustomerSnapshot ADD ClusterSegment NVARCHAR(50) NULL;
GO

-- 3. Add relationships matching the diagram, only if absent.
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
               WHERE parent_object_id=OBJECT_ID(N'dbo.FactCustomerRFMLive')
                 AND name=N'FK_FactCustomerRFMLive_ClusterProfile')
BEGIN
    ALTER TABLE dbo.FactCustomerRFMLive WITH CHECK
    ADD CONSTRAINT FK_FactCustomerRFMLive_ClusterProfile
        FOREIGN KEY (ClusterProfilingSK)
        REFERENCES dbo.DimClusterProfiling(ClusterProfilingSK);
END;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
               WHERE parent_object_id=OBJECT_ID(N'dbo.FactCustomerRFMLive')
                 AND name=N'FK_FactCustomerRFMLive_ModelConfig')
BEGIN
    ALTER TABLE dbo.FactCustomerRFMLive WITH CHECK
    ADD CONSTRAINT FK_FactCustomerRFMLive_ModelConfig
        FOREIGN KEY (ModelConfigKey)
        REFERENCES dbo.DimModelConfig(ModelConfigKey);
END;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
               WHERE parent_object_id=OBJECT_ID(N'dbo.FactCustomerSnapshot')
                 AND name=N'FK_FactCustomerSnapshot_ClusterProfile')
BEGIN
    ALTER TABLE dbo.FactCustomerSnapshot WITH CHECK
    ADD CONSTRAINT FK_FactCustomerSnapshot_ClusterProfile
        FOREIGN KEY (ClusterProfilingSK)
        REFERENCES dbo.DimClusterProfiling(ClusterProfilingSK);
END;
GO

-- 4. Single reusable RFM definition. Reads ORIGINAL CompanyX transactions
--    directly: it does NOT use, recreate, or require FactSales.
--    Includes ALL customers in DimCustomerProfiling (one output row per customer).
--    Counts distinct orders by aggregating order lines at order grain first.
CREATE OR ALTER FUNCTION dbo.ufn_ComputeCustomerRFM
(
    @AsOfDate DATE
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        c.CustomerKey_Str,
        CAST(MAX(s.OrderDate) AS DATETIME2(3)) AS LastPurchaseTimestamp,
        CAST(MAX(s.OrderDate) AS DATE) AS LastPurchaseDate,
        DATEDIFF(DAY, CAST(MAX(s.OrderDate) AS DATE), @AsOfDate) AS RecencyDays,
        COUNT(CASE
            WHEN s.OrderDate >= DATEADD(DAY, -364, @AsOfDate)
            THEN 1 END) AS Frequency365d,
        COALESCE(SUM(CASE
            WHEN s.OrderDate >= DATEADD(DAY, -364, @AsOfDate)
            THEN s.OrderAmount ELSE CAST(0 AS DECIMAL(19,4)) END),
            CAST(0 AS DECIMAL(19,4))) AS Monetary365d
    FROM dbo.DimCustomerProfiling AS c
    LEFT JOIN
    (
        SELECT
            CONVERT(NVARCHAR(20), h.CustomerID) AS CustomerKey_Str,
            h.SalesOrderID,
            h.OrderDate,
            SUM(CONVERT(DECIMAL(19,4), d.LineTotal)) AS OrderAmount
        FROM CompanyX.Sales.SalesOrderHeader AS h
        INNER JOIN CompanyX.Sales.SalesOrderDetail AS d
            ON d.SalesOrderID = h.SalesOrderID
        WHERE h.OrderDate < DATEADD(DAY, 1, @AsOfDate)
        -- TODO: Decide which SalesOrderHeader.Status values count as completed purchases.
        GROUP BY h.CustomerID, h.SalesOrderID, h.OrderDate
    ) AS s
        ON s.CustomerKey_Str = c.CustomerKey_Str
    GROUP BY c.CustomerKey_Str
);
GO

-- 5. Rebuild the current/updatable RFM summary, one row per customer.
--    Safe to rerun for the same @AsOfDate. MERGE does NOT remove old rows.
--    Cluster/model assignment is kept separate until your ML scoring flow exists.
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCustomerRFMLive
    @AsOfDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AsOfDate IS NULL
    BEGIN
        RAISERROR('AsOfDate is required.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Live RFM must not silently move backward to an older evaluation date.
        IF EXISTS (
            SELECT 1 FROM dbo.FactCustomerRFMLive
            WHERE AsOfDate > @AsOfDate
        )
            THROW 51120,
                'A newer live RFM date already exists. Use the historical RFM function for backfills.', 1;

        MERGE dbo.FactCustomerRFMLive WITH (HOLDLOCK) AS target
        USING
        (
            SELECT r.*, p.ClusterProfilingSK
            FROM dbo.ufn_ComputeCustomerRFM(@AsOfDate) AS r
            LEFT JOIN dbo.DimClusterProfiling AS p
                ON p.CustomerKey_Str = r.CustomerKey_Str
               AND p.IsCurrent = 1
        ) AS source
          ON source.CustomerKey_Str = target.CustomerKey_Str
        WHEN MATCHED AND EXISTS
        (
            SELECT source.LastPurchaseDate,
                   source.LastPurchaseTimestamp,
                   source.RecencyDays, source.Frequency365d,
                   source.Monetary365d, source.ClusterProfilingSK, @AsOfDate
            EXCEPT
            SELECT target.LastPurchaseDate,
                   target.LastPurchaseTimestamp,
                   target.RecencyDays, target.Frequency365d,
                   target.Monetary365d, target.ClusterProfilingSK, target.AsOfDate
        )
        THEN UPDATE SET
            target.AsOfDate = @AsOfDate,
            target.LastPurchaseDate = source.LastPurchaseDate,
            target.LastPurchaseTimestamp = source.LastPurchaseTimestamp,
            target.RecencyDays = source.RecencyDays,
            target.Frequency365d = source.Frequency365d,
            target.Monetary365d = source.Monetary365d,
            target.ClusterProfilingSK = source.ClusterProfilingSK,
            -- Prediction becomes stale when its RFM input or profile changes.
            target.ModelConfigKey = NULL,
            target.ClusterSegment = NULL,
            target.UpdatedAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (CustomerKey_Str, AsOfDate, LastPurchaseDate,
                    LastPurchaseTimestamp, RecencyDays,
                    Frequency365d, Monetary365d,
                    ClusterProfilingSK, ModelConfigKey, ClusterSegment)
            VALUES (source.CustomerKey_Str, @AsOfDate,
                    source.LastPurchaseDate, source.LastPurchaseTimestamp,
                    source.RecencyDays, source.Frequency365d, source.Monetary365d,
                    source.ClusterProfilingSK, NULL, NULL);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        ;THROW;
    END CATCH;
END;
GO

/*
 INITIAL HISTORICAL-SIMULATION LOAD (run manually only AFTER reviewing):

 EXEC dbo.usp_RefreshCustomerRFMLive @AsOfDate = '20140630';
 SELECT COUNT(*) AS CurrentCustomerCount FROM dbo.FactCustomerRFMLive;
 SELECT TOP (20) CustomerKey_Str, AsOfDate, LastPurchaseDate,
                 RecencyDays, Frequency365d, Monetary365d,
                 ClusterProfilingSK, ModelConfigKey, ClusterSegment
 FROM dbo.FactCustomerRFMLive ORDER BY CustomerKey_Str;

 For a real live system, after you have up-to-date source transactions:
 DECLARE @Today DATE = CONVERT(DATE, GETDATE());
 EXEC dbo.usp_RefreshCustomerRFMLive @AsOfDate = @Today;

 Monthly RFM snapshot insertion is implemented separately in
 dbo.usp_AppendMonthlyRFMSnapshot. Annual Python model
 publication/prediction remains pending. Snapshot.ModelConfigKey is nullable
 until predictions are published.

 No DROP TABLE is included. After checking the SQL Server dependency graph,
 and AFTER replacing the old SSIS Sales/Product flows, you may separately
 retire dbo.FactSales and dbo.DimProduct as requested by the team.
*/
