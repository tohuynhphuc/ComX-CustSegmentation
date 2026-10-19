
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

CREATE OR ALTER PROCEDURE
    dbo.usp_AppendMonthlyRFMSnapshot
    @SnapshotDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Snapshot must be the last day of a month.
    IF @SnapshotDate IS NULL
       OR @SnapshotDate <> EOMONTH(@SnapshotDate)
    BEGIN
        THROW 51104,
            'SnapshotDate must be a month-end date.', 1;
    END;

    DECLARE @SnapshotMonth DATE =
        DATEFROMPARTS(
            YEAR(@SnapshotDate),
            MONTH(@SnapshotDate),
            1
        );

    DECLARE @SnapshotDateKey INT =
        CONVERT(
            INT,
            CONVERT(CHAR(8), @SnapshotDate, 112)
        );

    -- Ensure that the date exists in DimDate.
    IF NOT EXISTS (
        SELECT 1
        FROM dbo.DimDate
        WHERE DateKey = @SnapshotDateKey
    )
    BEGIN
        THROW 51105,
            'Snapshot date is missing from DimDate.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Prevent concurrent runs from inserting
        -- duplicate customer-month records.
        DECLARE @LockResult INT;

        EXEC @LockResult = sys.sp_getapplock
            @Resource =
                'CompanyX_Monthly_Customer_RFM_Snapshot',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 15000;

        IF @LockResult < 0
        BEGIN
            THROW 51106,
                'Could not acquire snapshot lock.', 1;
        END;

        -- Insert historical RFM values.
        -- ML-related fields remain NULL.
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
            NULL AS ModelConfigKey,
            NULL AS ClusterProfilingSK,
            NULL AS ClusterSegment,
            r.LastPurchaseDate,
            r.RecencyDays,
            r.Frequency365d,
            r.Monetary365d,
            NULL AS ScaledR,
            NULL AS ScaledF,
            NULL AS ScaledM
        FROM dbo.ufn_ComputeCustomerRFM(
            @SnapshotDate
        ) AS r
        WHERE r.LastPurchaseDate IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM dbo.FactCustomerSnapshot AS s
                   WITH (UPDLOCK, HOLDLOCK)
              WHERE s.CustomerKey_Str =
                    r.CustomerKey_Str
                AND s.SnapshotMonth =
                    @SnapshotMonth
          );

        DECLARE @RowsInserted INT = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Report execution results.
        SELECT
            @SnapshotDate AS SnapshotDate,
            @RowsInserted AS RowsInserted,
            (
                SELECT COUNT(*)
                FROM dbo.FactCustomerSnapshot
                WHERE SnapshotMonth = @SnapshotMonth
            ) AS TotalRowsForMonth;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

PRINT 'Monthly RFM snapshot procedure installed.';
