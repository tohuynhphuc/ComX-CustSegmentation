
USE [CompanyX_DataWarehouse];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ============================================
-- 1. Verify required objects
-- ============================================

IF OBJECT_ID('dbo.FactCustomerSnapshot', 'U') IS NULL
    THROW 51101,
        'FactCustomerSnapshot table does not exist.', 1;

IF OBJECT_ID('dbo.ufn_ComputeCustomerRFM', 'IF') IS NULL
    THROW 51102,
        'RFM calculation function does not exist.', 1;

IF OBJECT_ID('dbo.DimDate', 'U') IS NULL
    THROW 51103,
        'DimDate table does not exist.', 1;

GO

-- ============================================
-- 2. Prepare FactCustomerSnapshot
-- ============================================

BEGIN TRY
    BEGIN TRANSACTION;

    -- Allow snapshots before ML predictions exist.
    IF EXISTS (
        SELECT 1
        FROM sys.columns
        WHERE object_id =
            OBJECT_ID('dbo.FactCustomerSnapshot')
          AND name = 'ModelConfigKey'
          AND is_nullable = 0
    )
    BEGIN
        -- Drop dependent index temporarily.
        IF EXISTS (
            SELECT 1 FROM sys.indexes
            WHERE object_id =
                OBJECT_ID('dbo.FactCustomerSnapshot')
              AND name = 'IX_FactCustomerSnapshot_Month'
        )
        BEGIN
            DROP INDEX IX_FactCustomerSnapshot_Month
            ON dbo.FactCustomerSnapshot;
        END;

        -- Drop existing model FK temporarily.
        IF EXISTS (
            SELECT 1 FROM sys.foreign_keys
            WHERE parent_object_id =
                OBJECT_ID('dbo.FactCustomerSnapshot')
              AND name = 'FK_FactCustomerSnapshot_Model'
        )
        BEGIN
            ALTER TABLE dbo.FactCustomerSnapshot
            DROP CONSTRAINT FK_FactCustomerSnapshot_Model;
        END;

        -- Make the model assignment optional for now.
        ALTER TABLE dbo.FactCustomerSnapshot
        ALTER COLUMN ModelConfigKey INT NULL;
    END;

    -- Add fields from the refined warehouse design.
    IF COL_LENGTH(
        'dbo.FactCustomerSnapshot',
        'ClusterProfilingSK'
    ) IS NULL
    BEGIN
        ALTER TABLE dbo.FactCustomerSnapshot
        ADD ClusterProfilingSK INT NULL;
    END;

    IF COL_LENGTH(
        'dbo.FactCustomerSnapshot',
        'ClusterSegment'
    ) IS NULL
    BEGIN
        ALTER TABLE dbo.FactCustomerSnapshot
        ADD ClusterSegment NVARCHAR(50) NULL;
    END;

    -- Restore the foreign key.
    IF NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys
        WHERE parent_object_id =
            OBJECT_ID('dbo.FactCustomerSnapshot')
          AND name = 'FK_FactCustomerSnapshot_Model'
    )
    BEGIN
        ALTER TABLE dbo.FactCustomerSnapshot
        WITH CHECK ADD CONSTRAINT
            FK_FactCustomerSnapshot_Model
        FOREIGN KEY (ModelConfigKey)
        REFERENCES dbo.DimModelConfig(ModelConfigKey);
    END;

    -- Restore the reporting index.
    IF NOT EXISTS (
        SELECT 1 FROM sys.indexes
        WHERE object_id =
            OBJECT_ID('dbo.FactCustomerSnapshot')
          AND name = 'IX_FactCustomerSnapshot_Month'
    )
    BEGIN
        CREATE NONCLUSTERED INDEX
            IX_FactCustomerSnapshot_Month
        ON dbo.FactCustomerSnapshot(
            SnapshotMonth, ModelConfigKey
        );
    END;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

-- ============================================
-- 3. Monthly snapshot stored procedure
-- ============================================

CREATE OR ALTER PROCEDURE dbo.usp_AppendMonthlyRFMSnapshot
    @SnapshotDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @SnapshotDate IS NULL OR @SnapshotDate <> EOMONTH(@SnapshotDate)
        THROW 51104, 'SnapshotDate must be a month-end date.', 1;

    DECLARE @SnapshotMonth DATE = DATEFROMPARTS(YEAR(@SnapshotDate), MONTH(@SnapshotDate), 1);
    DECLARE @SnapshotDateKey INT = CONVERT(INT, CONVERT(CHAR(8), @SnapshotDate, 112));

    IF NOT EXISTS (SELECT 1 FROM dbo.DimDate WHERE DateKey = @SnapshotDateKey)
        THROW 51105, 'Snapshot date is missing from DimDate.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @LockResult INT;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = 'CompanyX_Monthly_Customer_RFM_Snapshot',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 15000;

        IF @LockResult < 0
            THROW 51106, 'Could not acquire snapshot lock.', 1;

        -- Stage only customers for whom this month is not yet present.
        -- Resolve the SCD2 surrogate key before making any insert.
        SELECT
            r.CustomerKey_Str,
            r.LastPurchaseDate,
            r.RecencyDays,
            r.Frequency365d,
            r.Monetary365d,
            CASE
                WHEN history_at_date.ClusterProfilingSK IS NOT NULL
                    THEN history_at_date.ClusterProfilingSK
                WHEN earliest_profile.StartDate > @SnapshotDate
                    THEN earliest_profile.ClusterProfilingSK
                ELSE NULL
            END AS ClusterProfilingSK
        INTO #NewSnapshotRows
        FROM dbo.ufn_ComputeCustomerRFM(@SnapshotDate) AS r
        INNER JOIN dbo.DimCustomerProfiling AS dc
            ON dc.CustomerKey_Str = r.CustomerKey_Str
        OUTER APPLY
        (
            SELECT TOP (1) p.ClusterProfilingSK
            FROM dbo.DimClusterProfiling AS p
            WHERE p.CustomerKey_Str = r.CustomerKey_Str
              AND p.StartDate <= @SnapshotDate
              AND p.EndDate >= @SnapshotDate
            ORDER BY p.StartDate DESC, p.ClusterProfilingSK DESC
        ) AS history_at_date
        OUTER APPLY
        (
            SELECT TOP (1) p.ClusterProfilingSK, p.StartDate
            FROM dbo.DimClusterProfiling AS p
            WHERE p.CustomerKey_Str = r.CustomerKey_Str
            ORDER BY p.StartDate ASC, p.ClusterProfilingSK ASC
        ) AS earliest_profile
        WHERE r.LastPurchaseDate IS NOT NULL
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.FactCustomerSnapshot AS s WITH (UPDLOCK, HOLDLOCK)
              WHERE s.CustomerKey_Str = r.CustomerKey_Str
                AND s.SnapshotMonth = @SnapshotMonth
          );

        -- Do not silently omit eligible customers or leave their SK blank.
        IF EXISTS (SELECT 1 FROM #NewSnapshotRows WHERE ClusterProfilingSK IS NULL)
            THROW 51107,
                'Some snapshot customers have no usable DimClusterProfiling version. Load/repair customer profiles first.', 1;

        INSERT INTO dbo.FactCustomerSnapshot
        (
            CustomerKey_Str,
            SnapshotMonth,
            SnapshotDateKey,
            ModelConfigKey,
            ClusterProfilingSK,
            ClusterSegment,
            LastPurchaseDate,
            RecencyDays,
            Frequency365d,
            Monetary365d,
            ScaledR,
            ScaledF,
            ScaledM
        )
        SELECT
            r.CustomerKey_Str,
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
        FROM #NewSnapshotRows AS r;

        DECLARE @RowsInserted INT = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SELECT
            @SnapshotDate AS SnapshotDate,
            @RowsInserted AS RowsInserted,
            (SELECT COUNT(*)
             FROM dbo.FactCustomerSnapshot
             WHERE SnapshotMonth = @SnapshotMonth) AS TotalRowsForMonth;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO


PRINT 'Monthly RFM snapshot procedure installed.';
