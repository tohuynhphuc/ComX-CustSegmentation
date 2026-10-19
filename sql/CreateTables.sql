/*
 CompanyX Data Warehouse -- REFINED INITIAL SCHEMA (SQL Server)
 Fresh-install definition aligned with the final project architecture:
   DimCustomerProfiling, DimClusterProfiling, DimDate, DimModelConfig,
   FactCustomerRFMLive, FactCustomerSnapshot, stg.CustomerProfile.

 FactSales, DimProduct, and legacy SubDimCustomer are intentionally NOT created.
 Original transactions remain in the CompanyX source database.

 Safe to rerun for missing objects, but this file does NOT migrate existing table
 definitions. Use the schema-alignment RFM script for an existing installation.
 ModelConfigKey is nullable in snapshots until yearly models are published.
 ETL_Watermark remains OPTIONAL for legacy SSIS compatibility; the current
 comparison-based customer extract does not use a customer watermark.
*/
USE [CompanyX_DataWarehouse];


GO
SET NOCOUNT ON;

/* Required connection SET options for filtered indexes and indexed DML. */
SET ANSI_NULLS ON;

SET ANSI_PADDING ON;

SET ANSI_WARNINGS ON;

SET ARITHABORT ON;

SET CONCAT_NULL_YIELDS_NULL ON;

SET QUOTED_IDENTIFIER ON;

SET NUMERIC_ROUNDABORT OFF;


GO
/* Guard against a subtle existing-table schema mismatch.
   SSMS may continue later GO batches after THROW; if this error appears,
   stop/review the script rather than treating subsequent results as success. */
/* Check for an existing table with incompatible columns */
IF OBJECT_ID(N'dbo.ETL_Watermark', N'U') IS NOT NULL
   AND (COL_LENGTH(N'dbo.ETL_Watermark', N'PipelineName') IS NULL
        OR COL_LENGTH(N'dbo.ETL_Watermark', N'LastWatermark') IS NULL)
    BEGIN
        RAISERROR ('dbo.ETL_Watermark exists with incompatible columns. SSIS expects PipelineName and LastWatermark.', 16, 1);
        RETURN;
    END


GO
/* 1. Existing SSIS dimension: one row per source customer. */
IF OBJECT_ID(N'dbo.DimCustomerProfiling', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.DimCustomerProfiling (
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            BirthDate DATE NULL, -- Type 0
            Gender NVARCHAR (1) NULL, -- Type 1
            MaritalStatus NVARCHAR (1) NULL,
            TotalChildren INT NULL,
            HomeOwnerFlag BIT NULL,
            NumberCarsOwned INT NULL,
            CONSTRAINT PK_DimCustomerProfiling PRIMARY KEY CLUSTERED (CustomerKey_Str)
        );
    END


GO
/* 2. Existing SSIS history dimension: multiple versions per customer. */
IF OBJECT_ID(N'dbo.DimClusterProfiling', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.DimClusterProfiling (
            ClusterProfilingSK INT IDENTITY (1, 1) NOT NULL,
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            YearlyIncome NVARCHAR (30) NULL,
            Education NVARCHAR (30) NULL,
            Occupation NVARCHAR (30) NULL,
            CountryName NVARCHAR (50) NULL,
            RegionGroup NVARCHAR (50) NULL,
            StartDate DATE CONSTRAINT DF_DimClusterProfiling_StartDate DEFAULT (CONVERT (DATE, GETDATE())) NOT NULL,
            EndDate DATE CONSTRAINT DF_DimClusterProfiling_EndDate DEFAULT ('99991231') NOT NULL,
            IsCurrent BIT CONSTRAINT DF_DimClusterProfiling_IsCurrent DEFAULT (1) NOT NULL,
            CONSTRAINT PK_DimClusterProfiling PRIMARY KEY CLUSTERED (ClusterProfilingSK)
        );
    END


GO
/* Creates a uniqueness guard for current SCD records; fails if old data
   already contains multiple IsCurrent=1 records for the same customer. */
IF NOT EXISTS (SELECT 1
               FROM   sys.indexes
               WHERE  object_id = OBJECT_ID(N'dbo.DimClusterProfiling')
                      AND name = N'UX_DimClusterProfiling_OneCurrent')
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX UX_DimClusterProfiling_OneCurrent
            ON dbo.DimClusterProfiling(CustomerKey_Str) WHERE IsCurrent = 1;
    END


GO
/* 3. Optional legacy ETL watermark (unused by the active customer comparison ETL). */
IF OBJECT_ID(N'dbo.ETL_Watermark', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.ETL_Watermark (
            PipelineName VARCHAR (50) NOT NULL,
            LastWatermark DATETIME NOT NULL,
            CONSTRAINT PK_ETL_Watermark PRIMARY KEY CLUSTERED (PipelineName)
        );
    END


GO
/* Seed ONLY if absent. This does not move an existing extraction boundary. */
IF NOT EXISTS (SELECT 1
               FROM   dbo.ETL_Watermark
               WHERE  PipelineName = 'Customer_SCD')
    BEGIN
        INSERT  dbo.ETL_Watermark (PipelineName, LastWatermark)
        VALUES                   ('Customer_SCD', CONVERT (DATETIME, '20000101', 112));
    END


GO
/* 4. Calendar dimension: keep existing rows, create only when absent. */
IF OBJECT_ID(N'dbo.DimDate', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.DimDate (
            DateKey INT NOT NULL,
            [Date] DATE NOT NULL,
            DayName VARCHAR (9) NOT NULL,
            MonthName VARCHAR (9) NOT NULL,
            [Year] CHAR (4) NOT NULL,
            Quarter CHAR (2) NOT NULL,
            CONSTRAINT PK_DimDate PRIMARY KEY CLUSTERED (DateKey),
            CONSTRAINT UQ_DimDate_Date UNIQUE ([Date]),
            CONSTRAINT CHK_DimDate_DayName CHECK (DayName IN ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')),
            CONSTRAINT CHK_DimDate_MonthName CHECK (MonthName IN ('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December')),
            CONSTRAINT CHK_DimDate_Year CHECK ([Year] LIKE '[1-2][0-9][0-9][0-9]'),
            CONSTRAINT CHK_DimDate_Quarter CHECK (Quarter IN ('Q1', 'Q2', 'Q3', 'Q4'))
        );
    END


GO
/* Fill missing dates (2010-01-01 through today + 20 calendar years).
   English DATENAME is required to satisfy English CHECK constraints.
   Do not DROP and recreate DimDate: sales/snapshot facts may reference it. */
SET LANGUAGE us_english;

DECLARE @StartDate AS DATE = '20100101';

DECLARE @EndDate AS DATE = DATEADD(YEAR, 20, CONVERT (DATE, GETDATE()));

DECLARE @Count AS INT = DATEDIFF(DAY, @StartDate, @EndDate) + 1;

WITH Numbers
AS   (SELECT TOP (@Count) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
      FROM   sys.all_objects AS a CROSS JOIN sys.all_objects AS b),
     Dates
AS   (SELECT DATEADD(DAY, CONVERT (INT, n), @StartDate) AS TheDate
      FROM   Numbers)
INSERT dbo.DimDate (DateKey, [Date], DayName, MonthName, [Year], Quarter)
SELECT CONVERT (INT, CONVERT (CHAR (8), d.TheDate, 112)),
       d.TheDate,
       DATENAME(WEEKDAY, d.TheDate),
       DATENAME(MONTH, d.TheDate),
       CONVERT (CHAR (4), YEAR(d.TheDate)),
       CONCAT('Q', DATEPART(QUARTER, d.TheDate))
FROM   Dates AS d
WHERE  NOT EXISTS (SELECT 1
                   FROM   dbo.DimDate AS existing
                   WHERE  existing.[Date] = d.TheDate);


GO
/* 5. Annual clustering config; ONE ROW PER (ModelVersion, ClusterID).
   Preserve the user's chosen names/precision. Do not drop trained models. */
IF OBJECT_ID(N'dbo.DimModelConfig', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.DimModelConfig (
            ModelConfigKey INT IDENTITY (1, 1) NOT NULL,
            ModelVersion VARCHAR (50) NOT NULL,
            ClusterID INT NOT NULL,
            ClusterSegment NVARCHAR (50) NOT NULL, -- Unicode segment labels
            Mean_Scaled_R DECIMAL (18, 6) NOT NULL,
            Std_Scaled_R DECIMAL (18, 6) NOT NULL,
            Mean_Scaled_F DECIMAL (18, 6) NOT NULL,
            Std_Scaled_F DECIMAL (18, 6) NOT NULL,
            Mean_Scaled_M DECIMAL (18, 6) NOT NULL,
            Std_Scaled_M DECIMAL (18, 6) NOT NULL,
            Centroid_Scaled_R DECIMAL (18, 6) NOT NULL,
            Centroid_Scaled_F DECIMAL (18, 6) NOT NULL,
            Centroid_Scaled_M DECIMAL (18, 6) NOT NULL,
            IsActive BIT CONSTRAINT DF_DimModelConfig_IsActive DEFAULT (1) NOT NULL,
            StartDate DATE CONSTRAINT DF_DimModelConfig_StartDate DEFAULT (CONVERT (DATE, GETDATE())) NOT NULL,
            EndDate DATE CONSTRAINT DF_DimModelConfig_EndDate DEFAULT ('99991231') NOT NULL,
            CONSTRAINT PK_DimModelConfig PRIMARY KEY CLUSTERED (ModelConfigKey),
            CONSTRAINT UQ_DimModelConfig_VersionCluster UNIQUE (ModelVersion, ClusterID),
            CONSTRAINT CK_DimModelConfig_Dates CHECK (StartDate <= EndDate)
        );
    END


GO
/* For a pre-existing table without a (ModelVersion,ClusterID) constraint.
   Requires pre-existing rows to be unique; does NOT correct duplicates. */
IF NOT EXISTS (SELECT 1
               FROM   sys.indexes
               WHERE  object_id = OBJECT_ID(N'dbo.DimModelConfig')
                      AND (name = N'UX_DimModelConfig_VersionCluster'
                           OR name = N'UQ_DimModelConfig_VersionCluster'))
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX UX_DimModelConfig_VersionCluster
            ON dbo.DimModelConfig(ModelVersion, ClusterID);
    END


GO
/* 6. One-row-per-customer current rolling RFM metrics.
   Frequency is distinct orders in the 365-day window, not order lines.
   Monetary is summed sales line amount in the same 365-day window. */
IF OBJECT_ID(N'dbo.FactCustomerRFMLive', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FactCustomerRFMLive (
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            AsOfDate DATE NOT NULL,
            LastPurchaseDate DATE NULL,
            LastPurchaseTimestamp DATETIME2(3) NULL,
            RecencyDays INT NULL,
            Frequency365d INT NOT NULL,
            Monetary365d DECIMAL (19, 4) NOT NULL,
            ClusterProfilingSK INT NULL,
            ModelConfigKey INT NULL,
            ClusterSegment NVARCHAR(50) NULL,
            UpdatedAtUtc DATETIME2 (3) CONSTRAINT DF_FactCustomerRFMLive_UpdatedAtUtc DEFAULT (SYSUTCDATETIME()) NOT NULL,
            CONSTRAINT PK_FactCustomerRFMLive PRIMARY KEY CLUSTERED (CustomerKey_Str),
            CONSTRAINT FK_FactCustomerRFMLive_Customer FOREIGN KEY (CustomerKey_Str) REFERENCES dbo.DimCustomerProfiling (CustomerKey_Str),
            CONSTRAINT FK_FactCustomerRFMLive_ClusterProfile FOREIGN KEY (ClusterProfilingSK) REFERENCES dbo.DimClusterProfiling (ClusterProfilingSK),
            CONSTRAINT FK_FactCustomerRFMLive_ModelConfig FOREIGN KEY (ModelConfigKey) REFERENCES dbo.DimModelConfig (ModelConfigKey),
            CONSTRAINT CK_FactCustomerRFMLive_R CHECK (RecencyDays IS NULL
                                                       OR RecencyDays >= 0),
            CONSTRAINT CK_FactCustomerRFMLive_F CHECK (Frequency365d >= 0)
        );
    END


GO
/* 7. Monthly frozen historical RFM + clustering. A DimModelConfig key
   denotes a PARTICULAR cluster from a PARTICULAR annual model version. */
IF OBJECT_ID(N'dbo.FactCustomerSnapshot', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FactCustomerSnapshot (
            CustomerSnapshotKey BIGINT IDENTITY (1, 1) NOT NULL,
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            SnapshotMonth DATE NOT NULL, -- FIRST date of the reporting month
            SnapshotDateKey INT NOT NULL, -- YYYYMMDD of LAST day of the month
            ModelConfigKey INT NULL, -- NULL until an annual model has scored this snapshot
            ClusterProfilingSK INT NULL, -- NULL when historical SCD2 version cannot be established
            ClusterSegment NVARCHAR(50) NULL,
            LastPurchaseDate DATE NULL,
            RecencyDays INT NULL,
            Frequency365d INT NOT NULL,
            Monetary365d DECIMAL (19, 4) NOT NULL,
            ScaledR DECIMAL (18, 6) NULL,
            ScaledF DECIMAL (18, 6) NULL,
            ScaledM DECIMAL (18, 6) NULL,
            CreatedAtUtc DATETIME2 (3) CONSTRAINT DF_FactCustomerSnapshot_CreatedAtUtc DEFAULT (SYSUTCDATETIME()) NOT NULL,
            CONSTRAINT PK_FactCustomerSnapshot PRIMARY KEY CLUSTERED (CustomerSnapshotKey),
            CONSTRAINT UQ_FactCustomerSnapshot_CustomerMonth UNIQUE (CustomerKey_Str, SnapshotMonth),
            CONSTRAINT FK_FactCustomerSnapshot_Customer FOREIGN KEY (CustomerKey_Str) REFERENCES dbo.DimCustomerProfiling (CustomerKey_Str),
            CONSTRAINT FK_FactCustomerSnapshot_Model FOREIGN KEY (ModelConfigKey) REFERENCES dbo.DimModelConfig (ModelConfigKey),
            CONSTRAINT FK_FactCustomerSnapshot_ClusterProfile FOREIGN KEY (ClusterProfilingSK) REFERENCES dbo.DimClusterProfiling (ClusterProfilingSK),
            CONSTRAINT FK_FactCustomerSnapshot_Date FOREIGN KEY (SnapshotDateKey) REFERENCES dbo.DimDate (DateKey),
            CONSTRAINT CK_FactCustomerSnapshot_Month CHECK (DAY(SnapshotMonth) = 1),
            CONSTRAINT CK_FactCustomerSnapshot_DateKey CHECK (SnapshotDateKey = CONVERT (INT, CONVERT (CHAR (8), EOMONTH(SnapshotMonth), 112))),
            CONSTRAINT CK_FactCustomerSnapshot_Recency CHECK (RecencyDays IS NULL
                                                              OR RecencyDays >= 0),
            CONSTRAINT CK_FactCustomerSnapshot_Frequency CHECK (Frequency365d >= 0)
        );
    END


GO
IF NOT EXISTS (SELECT 1
               FROM   sys.indexes
               WHERE  object_id = OBJECT_ID(N'dbo.FactCustomerSnapshot')
                      AND name = N'IX_FactCustomerSnapshot_Month')
    BEGIN
        CREATE NONCLUSTERED INDEX IX_FactCustomerSnapshot_Month
            ON dbo.FactCustomerSnapshot(SnapshotMonth, ModelConfigKey);
    END


GO
/* 8. Staging table for your future set-based T-SQL MERGE / Type 2 code.
   BatchID allows controlled comparisons and safe per-batch cleanup. */
IF SCHEMA_ID(N'stg') IS NULL
    EXECUTE (N'CREATE SCHEMA stg');


GO
IF OBJECT_ID(N'stg.CustomerProfile', N'U') IS NULL
    BEGIN
        CREATE TABLE stg.CustomerProfile (
            BatchID UNIQUEIDENTIFIER NOT NULL,
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            BirthDate DATE NULL,
            Gender NVARCHAR (1) NULL,
            MaritalStatus NVARCHAR (1) NULL,
            TotalChildren INT NULL,
            HomeOwnerFlag BIT NULL,
            NumberCarsOwned INT NULL,
            YearlyIncome NVARCHAR (30) NULL,
            Education NVARCHAR (30) NULL,
            Occupation NVARCHAR (30) NULL,
            CountryName NVARCHAR (50) NULL,
            RegionGroup NVARCHAR (50) NULL,
            ExtractedAtUtc DATETIME2 (3) CONSTRAINT DF_stgCustomerProfile_ExtractedAtUtc DEFAULT (SYSUTCDATETIME()) NOT NULL,
            CONSTRAINT PK_stgCustomerProfile PRIMARY KEY CLUSTERED (BatchID, CustomerKey_Str)
        );
    END


GO
/* Inspect the refined tables present after setup. */
SELECT   s.name AS SchemaName,
         t.name AS TableName,
         SUM(CASE WHEN c.column_id IS NULL THEN 0 ELSE 1 END) AS ColumnCount
FROM     sys.tables AS t
         INNER JOIN
         sys.schemas AS s
         ON s.schema_id = t.schema_id
         LEFT OUTER JOIN
         sys.columns AS c
         ON c.object_id = t.object_id
WHERE    (s.name = N'dbo'
          AND t.name IN (N'DimCustomerProfiling', N'DimClusterProfiling', N'ETL_Watermark', N'DimDate', N'DimModelConfig', N'FactCustomerRFMLive', N'FactCustomerSnapshot'))
         OR (s.name = N'stg'
             AND t.name = N'CustomerProfile')
GROUP BY s.name, t.name
ORDER BY s.name, t.name;
