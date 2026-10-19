/*
 CompanyX_DataWarehouse — SSIS staging-based customer MERGE
 Based on CompanyX_DataWarehouse_Setup.sql and Package(2).dtsx.

 Run once in SSMS. Re-run to update the stored procedure.
 No warehouse tables are dropped or truncated by this script.

 Assumptions:
 - dbo.DimCustomerProfiling has one row per CustomerKey_Str.
 - dbo.DimClusterProfiling tracks history via StartDate/EndDate DATE and IsCurrent BIT.
 - EndDate is INCLUSIVE: retired row ends the day before its replacement begins.
 - stg.CustomerProfile primary key is (BatchID, CustomerKey_Str).
 - Use @BatchID to restrict each run to its own staged records.
 - Use @EffectiveDate to date SCD changes; defaults to SQL Server local current date.
 - No customer deletion inferred from a missing staging row.
 - Different Type 2 versions on the same calendar day are rejected because DATE
   cannot represent multiple nonoverlapping daily versions.
 - SQL Server 2016 SP1+ for CREATE OR ALTER; otherwise use CREATE/ALTER separately.
*/
USE [CompanyX_DataWarehouse];
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_ApplyCustomerProfileBatch
    @BatchID UNIQUEIDENTIFIER,
    @EffectiveDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ApplyDate DATE = COALESCE(@EffectiveDate, CONVERT(DATE, GETDATE()));

    IF @BatchID IS NULL
    BEGIN
        RAISERROR('BatchID must be supplied.', 16, 1);
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM stg.CustomerProfile WHERE BatchID = @BatchID)
    BEGIN
        RAISERROR('No rows found in stg.CustomerProfile for the supplied BatchID.', 16, 1);
        RETURN;
    END;

    -- Lock is held across the two MERGEs + history insertion.
    -- Intended for ONE SSIS merge run at a time.
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Ensure only one customer merge procedure runs at a time.
        DECLARE @AppLockResult INT;
        EXEC @AppLockResult = sys.sp_getapplock
            @Resource = N'CompanyX_CustomerProfile_Merge',
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = 15000;
        IF @AppLockResult < 0
        BEGIN
            RAISERROR('Could not acquire exclusive customer-merge lock.', 16, 1);
        END;

        /* Reject an already-corrupt history situation before modifying anything.
           If a changed historical row was inserted today, DATE resolution cannot
           represent a different SCD2 version on the same calendar day. */
        IF EXISTS (
            SELECT 1
            FROM stg.CustomerProfile AS s
            INNER JOIN dbo.DimClusterProfiling AS t WITH (UPDLOCK, HOLDLOCK)
                ON t.CustomerKey_Str = s.CustomerKey_Str AND t.IsCurrent = 1
            WHERE s.BatchID = @BatchID
              AND t.StartDate >= @ApplyDate
              AND EXISTS (
                  SELECT s.YearlyIncome, s.Education, s.Occupation,
                         s.CountryName, s.RegionGroup
                  EXCEPT
                  SELECT t.YearlyIncome, t.Education, t.Occupation,
                         t.CountryName, t.RegionGroup
              )
        )
        BEGIN
            RAISERROR('A changed Type 2 row already starts on/after EffectiveDate. DATE-based history cannot represent this change; choose a later effective date or use DATETIME2-based history.', 16, 1);
        END;

        /* A. Type 0 / Type 1.
           BirthDate is Type 0: inserted for new customer, never overwritten.
           Five Type 1 attributes are overwritten on change.
           EXCEPT is null-safe when comparing equivalent typed columns. */
        MERGE dbo.DimCustomerProfiling WITH (HOLDLOCK) AS target
        USING (
            SELECT CustomerKey_Str, BirthDate, Gender, MaritalStatus,
                   TotalChildren, HomeOwnerFlag, NumberCarsOwned
            FROM stg.CustomerProfile
            WHERE BatchID = @BatchID
        ) AS source
        ON target.CustomerKey_Str = source.CustomerKey_Str
        WHEN MATCHED AND EXISTS (
            SELECT source.Gender, source.MaritalStatus,
                   source.TotalChildren, source.HomeOwnerFlag,
                   source.NumberCarsOwned
            EXCEPT
            SELECT target.Gender, target.MaritalStatus,
                   target.TotalChildren, target.HomeOwnerFlag,
                   target.NumberCarsOwned
        )
        THEN UPDATE SET
            Gender = source.Gender,
            MaritalStatus = source.MaritalStatus,
            TotalChildren = source.TotalChildren,
            HomeOwnerFlag = source.HomeOwnerFlag,
            NumberCarsOwned = source.NumberCarsOwned
        WHEN NOT MATCHED BY TARGET
        THEN INSERT (
            CustomerKey_Str, BirthDate, Gender, MaritalStatus,
            TotalChildren, HomeOwnerFlag, NumberCarsOwned
        )
        VALUES (
            source.CustomerKey_Str, source.BirthDate, source.Gender,
            source.MaritalStatus, source.TotalChildren,
            source.HomeOwnerFlag, source.NumberCarsOwned
        );

        /* B. Type 2.
           - New business key => insert current version.
           - Changed key => expire current version and record the key in
             @ClusterActions; follow with a separate INSERT of its new version.
           - Unchanged => do nothing.
           - No WHEN NOT MATCHED BY SOURCE: partial staging batches must not
             implicitly retire absent customers.
        */
        DECLARE @ClusterActions TABLE (
            ActionName NVARCHAR(10) NOT NULL,
            CustomerKey_Str NVARCHAR(20) NOT NULL
        );

        MERGE dbo.DimClusterProfiling WITH (HOLDLOCK) AS target
        USING (
            SELECT CustomerKey_Str, YearlyIncome, Education, Occupation,
                   CountryName, RegionGroup
            FROM stg.CustomerProfile
            WHERE BatchID = @BatchID
        ) AS source
        ON target.CustomerKey_Str = source.CustomerKey_Str AND target.IsCurrent = 1
        WHEN MATCHED AND EXISTS (
            SELECT source.YearlyIncome, source.Education, source.Occupation,
                   source.CountryName, source.RegionGroup
            EXCEPT
            SELECT target.YearlyIncome, target.Education, target.Occupation,
                   target.CountryName, target.RegionGroup
        )
        THEN UPDATE SET
            IsCurrent = 0,
            EndDate = DATEADD(DAY, -1, @ApplyDate)
        WHEN NOT MATCHED BY TARGET
        THEN INSERT (
            CustomerKey_Str, YearlyIncome, Education, Occupation,
            CountryName, RegionGroup, StartDate, EndDate, IsCurrent
        )
        VALUES (
            source.CustomerKey_Str, source.YearlyIncome, source.Education,
            source.Occupation, source.CountryName, source.RegionGroup,
            @ApplyDate, CONVERT(DATE, '99991231', 112), 1
        )
        OUTPUT $action, inserted.CustomerKey_Str
        INTO @ClusterActions (ActionName, CustomerKey_Str);

        /* C. Add replacement rows for those old versions just expired. */
        INSERT dbo.DimClusterProfiling (
            CustomerKey_Str, YearlyIncome, Education, Occupation,
            CountryName, RegionGroup, StartDate, EndDate, IsCurrent
        )
        SELECT
            s.CustomerKey_Str, s.YearlyIncome, s.Education, s.Occupation,
            s.CountryName, s.RegionGroup, @ApplyDate,
            CONVERT(DATE, '99991231', 112), 1
        FROM stg.CustomerProfile AS s
        JOIN @ClusterActions AS a
          ON a.CustomerKey_Str = s.CustomerKey_Str
         AND a.ActionName = N'UPDATE'
        WHERE s.BatchID = @BatchID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(N'Customer MERGE failed: %s', 16, 1, @ErrorMessage);
        RETURN;
    END CATCH;
END;
GO

-- Verification: non-null ProcedureID means it is installed.
SELECT OBJECT_ID(N'dbo.usp_ApplyCustomerProfileBatch', N'P') AS ProcedureID;
GO
