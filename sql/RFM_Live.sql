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
        CONVERT(NVARCHAR(20), c.CustomerID) AS CustomerKey_Str,
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
    FROM CompanyX.Sales.Customer AS c
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
        ON s.CustomerKey_Str = CONVERT(NVARCHAR(20), c.CustomerID)
    GROUP BY c.CustomerID
);
GO

-- RFM_Live uses its own watermark; Customer_SCD is NOT modified.
-- The existing ETL_Watermark table has:
--   PipelineName varchar(50) primary key, LastWatermark datetime not null.
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCustomerRFMLive
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Cutoff DATETIME = GETDATE(); -- extraction clock, NOT purchase date
    DECLARE @LastWatermark DATETIME;
    DECLARE @LockResult INT;
    DECLARE @ChangedRows INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Prevent overlapping SQL Agent executions from processing the same window.
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'CompanyX_RFM_Live_Refresh',
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = 60000;

        IF @LockResult < 0
            THROW 51121, 'Could not acquire RFM Live refresh lock.', 1;

        IF NOT EXISTS (
            SELECT 1 FROM dbo.ETL_Watermark WITH (UPDLOCK, HOLDLOCK)
            WHERE PipelineName = 'RFM_Live'
        )
        BEGIN
            -- First run will initialize customers from historical source orders.
            INSERT dbo.ETL_Watermark (PipelineName, LastWatermark)
            VALUES ('RFM_Live', CONVERT(DATETIME, '19000101', 112));
        END;

        SELECT @LastWatermark = LastWatermark
        FROM dbo.ETL_Watermark WITH (UPDLOCK, HOLDLOCK)
        WHERE PipelineName = 'RFM_Live';

        CREATE TABLE #AffectedCustomers (
            CustomerID INT NOT NULL PRIMARY KEY
        );

        -- Both header and detail modifications can affect a customer's RFM.
        -- Inclusive lower / exclusive upper bound avoids missing equal timestamps.
        INSERT #AffectedCustomers (CustomerID)
        SELECT CustomerID
        FROM (
            SELECT h.CustomerID
            FROM CompanyX.Sales.SalesOrderHeader AS h
            WHERE h.ModifiedDate >= @LastWatermark
              AND h.ModifiedDate < @Cutoff

            UNION

            SELECT h.CustomerID
            FROM CompanyX.Sales.SalesOrderDetail AS d
            JOIN CompanyX.Sales.SalesOrderHeader AS h
              ON h.SalesOrderID = d.SalesOrderID
            WHERE d.ModifiedDate >= @LastWatermark
              AND d.ModifiedDate < @Cutoff
        ) AS ChangedSales;

        -- Recalculate full purchase history ONLY for affected customers,
        -- evaluated at each customer's latest purchase date.
        ;WITH CustomerOrders AS (
            SELECT h.CustomerID, h.SalesOrderID, h.OrderDate,
                   SUM(CONVERT(DECIMAL(19, 4), d.LineTotal)) AS OrderAmount
            FROM #AffectedCustomers AS a
            JOIN CompanyX.Sales.SalesOrderHeader AS h
              ON h.CustomerID = a.CustomerID
            JOIN CompanyX.Sales.SalesOrderDetail AS d
              ON d.SalesOrderID = h.SalesOrderID
            GROUP BY h.CustomerID, h.SalesOrderID, h.OrderDate
        ),
        LatestPurchase AS (
            SELECT CustomerID, MAX(OrderDate) AS LastOrderTimestamp
            FROM CustomerOrders
            GROUP BY CustomerID
        ),
        CustomerRFM AS (
            SELECT CONVERT(NVARCHAR(20), o.CustomerID) AS CustomerKey_Str,
                   CONVERT(DATE, l.LastOrderTimestamp) AS AsOfDate,
                   CONVERT(DATETIME2(3), l.LastOrderTimestamp) AS LastPurchaseTimestamp,
                   CONVERT(DATE, l.LastOrderTimestamp) AS LastPurchaseDate,
                   CAST(0 AS INT) AS RecencyDays,
                   COUNT(CASE
                       WHEN o.OrderDate >= DATEADD(DAY, -364, CONVERT(DATE, l.LastOrderTimestamp))
                       THEN 1 END) AS Frequency365d,
                   COALESCE(SUM(CASE
                       WHEN o.OrderDate >= DATEADD(DAY, -364, CONVERT(DATE, l.LastOrderTimestamp))
                       THEN o.OrderAmount ELSE CONVERT(DECIMAL(19,4), 0) END),
                       CONVERT(DECIMAL(19,4), 0)) AS Monetary365d
            FROM CustomerOrders AS o
            JOIN LatestPurchase AS l ON l.CustomerID = o.CustomerID
            GROUP BY o.CustomerID, l.LastOrderTimestamp
        )
        MERGE dbo.FactCustomerRFMLive WITH (HOLDLOCK) AS target
        USING (
            SELECT r.*, p.ClusterProfilingSK
            FROM CustomerRFM AS r
            JOIN dbo.DimCustomerProfiling AS dc
              ON dc.CustomerKey_Str = r.CustomerKey_Str
            LEFT JOIN dbo.DimClusterProfiling AS p
              ON p.CustomerKey_Str = r.CustomerKey_Str
             AND p.IsCurrent = 1
        ) AS source
          ON source.CustomerKey_Str = target.CustomerKey_Str
        WHEN MATCHED AND EXISTS
        (
            SELECT source.AsOfDate, source.LastPurchaseDate,
                   source.LastPurchaseTimestamp, source.RecencyDays,
                   source.Frequency365d, source.Monetary365d,
                   source.ClusterProfilingSK
            EXCEPT
            SELECT target.AsOfDate, target.LastPurchaseDate,
                   target.LastPurchaseTimestamp, target.RecencyDays,
                   target.Frequency365d, target.Monetary365d,
                   target.ClusterProfilingSK
        ) THEN
            UPDATE SET
                target.AsOfDate = source.AsOfDate,
                target.LastPurchaseDate = source.LastPurchaseDate,
                target.LastPurchaseTimestamp = source.LastPurchaseTimestamp,
                target.RecencyDays = source.RecencyDays,
                target.Frequency365d = source.Frequency365d,
                target.Monetary365d = source.Monetary365d,
                target.ClusterProfilingSK = source.ClusterProfilingSK,
                target.ModelConfigKey = NULL,
                target.ClusterSegment = NULL,
                target.UpdatedAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (CustomerKey_Str, AsOfDate, LastPurchaseDate,
                    LastPurchaseTimestamp, RecencyDays, Frequency365d,
                    Monetary365d, ClusterProfilingSK, ModelConfigKey, ClusterSegment)
            VALUES (source.CustomerKey_Str, source.AsOfDate, source.LastPurchaseDate,
                    source.LastPurchaseTimestamp, source.RecencyDays,
                    source.Frequency365d, source.Monetary365d,
                    source.ClusterProfilingSK, NULL, NULL);

        SET @ChangedRows = @@ROWCOUNT;

        -- Advance watermark in the SAME transaction as the RFM changes.
        UPDATE dbo.ETL_Watermark
        SET LastWatermark = @Cutoff
        WHERE PipelineName = 'RFM_Live';

        COMMIT TRANSACTION;

        PRINT CONCAT('RFM Live inserted/updated rows: ', @ChangedRows,
                     '; processed through ', CONVERT(VARCHAR(23), @Cutoff, 121));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
