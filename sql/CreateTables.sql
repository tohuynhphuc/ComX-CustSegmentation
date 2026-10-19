/*
 CompanyX Data Warehouse -- NON-DESTRUCTIVE, RERUNNABLE INITIAL SCHEMA
 Prepared against the uploaded Package(1).dtsx and supplied DDL.
 SQL Server (T-SQL); execute in SSMS with a login able to CREATE TABLE/SCHEMA.
 Assumes [CompanyX_DataWarehouse] database already exists.

 IMPORTANT:
  - Does not DROP/TRUNCATE existing tables or overwrite existing data.
  - IF NOT EXISTS does not upgrade an already-existing table's columns/types.
  - FactSales, RFM, snapshot and staging definitions are PROPOSED: validate grain,
    time windows, currencies and source-to-warehouse mappings with your team.
  - dbo.ETL_Watermark names match the supplied SSIS package (PipelineName,
    LastWatermark), NOT the alternate DDL using TableName/LastProcessedDate.
  - The new SCD set-based MERGE pipeline is NOT created by this DDL alone.
  - ClusterSegment uses NVARCHAR(50) (Unicode), an intentional improvement
    over the user-provided VARCHAR(50).
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
/* 3. Product dimension used by Product Data Flow.
   Nullable category fields allow products with no subcategory. */
IF OBJECT_ID(N'dbo.DimProduct', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.DimProduct (
            ProductID INT NOT NULL,
            ProductName NVARCHAR (50) NOT NULL,
            ProductSubcategoryID INT NULL,
            ModifiedDate DATETIME NOT NULL,
            ProductCategoryID INT NULL,
            SubcategoryName NVARCHAR (50) NULL,
            CategoryName NVARCHAR (50) NULL,
            CONSTRAINT PK_DimProduct PRIMARY KEY CLUSTERED (ProductID)
        );
    END


GO
/* 4. SSIS watermark: EXACT column names referenced in current package. */
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
/* 5. Calendar dimension: keep existing rows, create only when absent. */
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
/* 6. Annual clustering config; ONE ROW PER (ModelVersion, ClusterID).
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
/* 7. One-row-per-customer current rolling RFM metrics.
   Frequency is distinct orders in the 365-day window, not order lines.
   Monetary is summed sales line amount in the same 365-day window. */
IF OBJECT_ID(N'dbo.FactCustomerRFMLive', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FactCustomerRFMLive (
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            AsOfDate DATE NOT NULL,
            LastPurchaseDate DATE NULL,
            RecencyDays INT NULL,
            Frequency365d INT NOT NULL,
            Monetary365d DECIMAL (19, 4) NOT NULL,
            UpdatedAtUtc DATETIME2 (3) CONSTRAINT DF_FactCustomerRFMLive_UpdatedAtUtc DEFAULT (SYSUTCDATETIME()) NOT NULL,
            CONSTRAINT PK_FactCustomerRFMLive PRIMARY KEY CLUSTERED (CustomerKey_Str),
            CONSTRAINT FK_FactCustomerRFMLive_Customer FOREIGN KEY (CustomerKey_Str) REFERENCES dbo.DimCustomerProfiling (CustomerKey_Str),
            CONSTRAINT CK_FactCustomerRFMLive_R CHECK (RecencyDays IS NULL
                                                       OR RecencyDays >= 0),
            CONSTRAINT CK_FactCustomerRFMLive_F CHECK (Frequency365d >= 0)
        );
    END


GO
/* 8. Monthly frozen historical RFM + clustering. A DimModelConfig key
   denotes a PARTICULAR cluster from a PARTICULAR annual model version. */
IF OBJECT_ID(N'dbo.FactCustomerSnapshot', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FactCustomerSnapshot (
            CustomerSnapshotKey BIGINT IDENTITY (1, 1) NOT NULL,
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            SnapshotMonth DATE NOT NULL, -- FIRST date of the reporting month
            SnapshotDateKey INT NOT NULL, -- YYYYMMDD of LAST day of the month
            ModelConfigKey INT NOT NULL, -- assigned cluster row in DimModelConfig
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
/* 9. Proposed FactSales at ORDER-LINE grain for RFM calculations.
   Requires a new/other SSIS process; NOT loaded by the uploaded package.
   Excludes order-level tax/freight; amount defined as line revenue. */
IF OBJECT_ID(N'dbo.FactSales', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FactSales (
            SalesOrderID INT NOT NULL,
            SalesOrderDetailID INT NOT NULL,
            CustomerKey_Str NVARCHAR (20) NOT NULL,
            ProductID INT NOT NULL,
            OrderDateKey INT NOT NULL, -- YYYYMMDD
            OrderQty SMALLINT NOT NULL,
            UnitPrice DECIMAL (19, 4) NOT NULL,
            SalesAmount DECIMAL (19, 4) NOT NULL, -- source SalesOrderDetail.LineTotal
            ModifiedDate DATETIME NULL,
            CONSTRAINT PK_FactSales PRIMARY KEY CLUSTERED (SalesOrderID, SalesOrderDetailID),
            CONSTRAINT FK_FactSales_Customer FOREIGN KEY (CustomerKey_Str) REFERENCES dbo.DimCustomerProfiling (CustomerKey_Str),
            CONSTRAINT FK_FactSales_Product FOREIGN KEY (ProductID) REFERENCES dbo.DimProduct (ProductID),
            CONSTRAINT FK_FactSales_Date FOREIGN KEY (OrderDateKey) REFERENCES dbo.DimDate (DateKey),
            CONSTRAINT CK_FactSales_Quantity CHECK (OrderQty > 0)
        );
    END


GO
IF NOT EXISTS (SELECT 1
               FROM   sys.indexes
               WHERE  object_id = OBJECT_ID(N'dbo.FactSales')
                      AND name = N'IX_FactSales_CustomerDate')
    BEGIN
        CREATE NONCLUSTERED INDEX IX_FactSales_CustomerDate
            ON dbo.FactSales(CustomerKey_Str, OrderDateKey)
            INCLUDE(SalesOrderID, SalesAmount);
    END


GO
/* 10. Staging table for your future set-based T-SQL MERGE / Type 2 code.
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
/* 11. LEGACY / OPTIONAL: only needed if you intend to run the old
   SubDimCustomer SSIS data flow. Included so that old task has a destination. */
IF OBJECT_ID(N'dbo.SubDimCustomer', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.SubDimCustomer (
            SCustKey NVARCHAR (22) NOT NULL,
            MaritalStatus NVARCHAR (1) NULL,
            Gender NVARCHAR (1) NULL,
            TotalChildren INT NULL,
            HomeOwnerFlag BIT NULL,
            NumberCarsOwned INT NULL,
            CONSTRAINT PK_SubDimCustomer PRIMARY KEY CLUSTERED (SCustKey)
        );
    END


GO
/* Inspect what exists. Does not prove compatibility for every old table. */
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
          AND t.name IN (N'DimCustomerProfiling', N'DimClusterProfiling', N'DimProduct', N'ETL_Watermark', N'DimDate', N'DimModelConfig', N'FactCustomerRFMLive', N'FactCustomerSnapshot', N'FactSales', N'SubDimCustomer'))
         OR (s.name = N'stg'
             AND t.name = N'CustomerProfile')
GROUP BY s.name, t.name
ORDER BY s.name, t.name;
