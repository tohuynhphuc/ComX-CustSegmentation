-- ====================================================================
-- Data Warehouse Initialization Script for CompanyX_DW
-- Schema matching:
--   1. DimProduct (SCD Type 1)
--   2. DimDate (SCD Type 0)
--   3. SubDimCustomer (SCD Type 0 + 1)
--   4. DimCustomer (SCD Type 2)
--   5. DimCustomerProfile (SCD Type 4)
--   6. FactSales (Line-item/Order Fact)
-- ====================================================================

DROP DATABASE IF EXISTS CompanyX_DW;
CREATE DATABASE CompanyX_DW;
USE CompanyX_DW;

-- 1. DimProduct (SCD Type 1)
CREATE TABLE DimProduct (
    ProductKey INT PRIMARY KEY,
    ProductName VARCHAR(255) NOT NULL,
    Category VARCHAR(100) NOT NULL
);

-- 2. DimDate (SCD Type 0)
CREATE TABLE DimDate (
    DateKey INT PRIMARY KEY,
    DayName VARCHAR(20) NOT NULL,
    MonthName VARCHAR(20) NOT NULL,
    Year INT NOT NULL,
    Quarter VARCHAR(10) NOT NULL
);

-- 3. SubDimCustomer (SCD Type 0 + 1 Outrigger)
-- Holds static/infrequent attributes per natural CustomerKey
CREATE TABLE SubDimCustomer (
    CustomerKey VARCHAR(50) PRIMARY KEY,
    Gender VARCHAR(10),
    MaritalStatus VARCHAR(10),
    TotalChildren INT,
    HomeOwnerFlag TINYINT,
    NumberCarsOwned INT
);

-- 4. DimCustomer (SCD Type 2)
-- Tracks major demographic history via SurrogateKey versions
CREATE TABLE DimCustomer (
    SurrogateKey VARCHAR(50) PRIMARY KEY,
    CustomerKey VARCHAR(50) NOT NULL,
    BirthDate DATE,
    Education VARCHAR(50),
    Occupation VARCHAR(100),
    YearlyIncome VARCHAR(50),
    CountryName VARCHAR(50),
    RegionGroup VARCHAR(50),
    isActivate TINYINT NOT NULL DEFAULT 1,
    StartDate DATE NOT NULL,
    EndDate DATE NOT NULL,
    CONSTRAINT fk_dimcustomer_subdim
        FOREIGN KEY (CustomerKey) REFERENCES SubDimCustomer(CustomerKey)
);

-- 5. DimCustomerProfile (SCD Type 4 Mini-Dimension for RFM & Clusters)
CREATE TABLE DimCustomerProfile (
    ProfileKey INT PRIMARY KEY,
    ClusterID INT NULL,
    CustomerSegment VARCHAR(50) NULL,
    Recency INT,
    Frequency INT,
    Monetary DECIMAL(15, 2)
);

-- 6. FactSales
CREATE TABLE FactSales (
    SalesID INT PRIMARY KEY,
    ProductKey INT NOT NULL,
    CustomerKey VARCHAR(50) NOT NULL,
    OrderDateKey INT NOT NULL,
    ProfileKey INT NOT NULL,
    OrderQty INT NOT NULL,
    TotalSpent DECIMAL(15, 2) NOT NULL,
    CONSTRAINT fk_fact_product
        FOREIGN KEY (ProductKey) REFERENCES DimProduct(ProductKey),
    CONSTRAINT fk_fact_customer
        FOREIGN KEY (CustomerKey) REFERENCES DimCustomer(SurrogateKey),
    CONSTRAINT fk_fact_date
        FOREIGN KEY (OrderDateKey) REFERENCES DimDate(DateKey),
    CONSTRAINT fk_fact_profile
        FOREIGN KEY (ProfileKey) REFERENCES DimCustomerProfile(ProfileKey)
);
