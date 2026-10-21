/*
CompanyX source/warehouse validation queries for the report.
READ ONLY. Run in SSMS. Adjust B2C population rules and the reference date
before treating the results as final, since BI may filter differently.
No reported numbers are assumed to be correct without executing these queries.
*/

-- 1. Customer lifetime order-frequency distribution.
-- This uses individual/B2C source customers (PersonID IS NOT NULL)
-- with at least one order dated on or before 2014-06-30.
WITH PerCustomer AS (
 SELECT h.CustomerID, COUNT(DISTINCT h.SalesOrderID) AS LifetimeOrderCount
 FROM CompanyX.Sales.SalesOrderHeader AS h
 JOIN CompanyX.Sales.Customer AS c ON c.CustomerID = h.CustomerID
 WHERE c.PersonID IS NOT NULL
   AND h.OrderDate < '2014-07-01'
 GROUP BY h.CustomerID
)
SELECT CASE WHEN LifetimeOrderCount=1 THEN 'Exactly 1'
            WHEN LifetimeOrderCount=2 THEN 'Exactly 2'
            WHEN LifetimeOrderCount BETWEEN 3 AND 5 THEN '3-5'
            ELSE '6 or more' END AS OrderGroup,
       COUNT(*) AS Customers,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(8,2)) AS PercentOfCustomers
FROM PerCustomer
GROUP BY CASE WHEN LifetimeOrderCount=1 THEN 'Exactly 1'
              WHEN LifetimeOrderCount=2 THEN 'Exactly 2'
              WHEN LifetimeOrderCount BETWEEN 3 AND 5 THEN '3-5'
              ELSE '6 or more' END;

-- 2. One-item/two-item basket counts by order lines and by quantity.
-- Important: a single line may represent quantity > 1.
WITH Basket AS (
  SELECT h.SalesOrderID, COUNT(*) AS DistinctLines, SUM(d.OrderQty) AS ItemQuantity
  FROM CompanyX.Sales.SalesOrderHeader h
  INNER JOIN CompanyX.Sales.SalesOrderDetail d ON d.SalesOrderID = h.SalesOrderID
  WHERE h.OrderDate < '2014-07-01'
  GROUP BY h.SalesOrderID
)
SELECT SUM(CASE WHEN DistinctLines=1 THEN 1 ELSE 0 END) AS OneLineOrders,
       SUM(CASE WHEN DistinctLines=2 THEN 1 ELSE 0 END) AS TwoLineOrders,
       SUM(CASE WHEN ItemQuantity=1 THEN 1 ELSE 0 END) AS OneUnitOrders,
       SUM(CASE WHEN ItemQuantity=2 THEN 1 ELSE 0 END) AS TwoUnitOrders
FROM Basket;

-- 3. Number of individual customers who have bought a bicycle but have
-- never ordered any Clothing or Accessories items by the reporting cutoff.
WITH CustomerCategory AS (
  SELECT h.CustomerID,
    MAX(CASE WHEN pc.Name='Bikes' THEN 1 ELSE 0 END) AS HasBikes,
    MAX(CASE WHEN pc.Name IN ('Accessories','Clothing') THEN 1 ELSE 0 END) AS HasComplement
  FROM CompanyX.Sales.SalesOrderHeader h
  JOIN CompanyX.Sales.Customer c ON c.CustomerID = h.CustomerID
  JOIN CompanyX.Sales.SalesOrderDetail d ON d.SalesOrderID = h.SalesOrderID
  JOIN CompanyX.Production.Product p ON p.ProductID = d.ProductID
  JOIN CompanyX.Production.ProductSubcategory ps ON ps.ProductSubcategoryID = p.ProductSubcategoryID
  JOIN CompanyX.Production.ProductCategory pc ON pc.ProductCategoryID = ps.ProductCategoryID
  WHERE c.PersonID IS NOT NULL AND h.OrderDate < '2014-07-01'
  GROUP BY h.CustomerID
)
SELECT COUNT(*) AS BikesOnlyCustomers
FROM CustomerCategory
WHERE HasBikes=1 AND HasComplement=0;

-- 4. Customer inactivity as at 2014-06-30 (all historical B2C orders).
WITH LastOrder AS (
 SELECT h.CustomerID, CAST(MAX(h.OrderDate) AS date) AS LastPurchaseDate
 FROM CompanyX.Sales.SalesOrderHeader h
 JOIN CompanyX.Sales.Customer c ON c.CustomerID = h.CustomerID
 WHERE c.PersonID IS NOT NULL AND h.OrderDate < '2014-07-01'
 GROUP BY h.CustomerID
)
SELECT COUNT(*) AS PurchasedByReferenceDate,
       SUM(CASE WHEN DATEDIFF(DAY,LastPurchaseDate,'2014-06-30')>100 THEN 1 ELSE 0 END) AS InactiveOver100Days,
       SUM(CASE WHEN DATEDIFF(DAY,LastPurchaseDate,'2014-06-30')>180 THEN 1 ELSE 0 END) AS InactiveOver180Days
FROM LastOrder;

-- 5. Warehouse snapshot counts, cluster shares, and RFM aggregates.
USE CompanyX_DataWarehouse;
SELECT SnapshotDateKey, COUNT(*) AS RowsInSnapshot,
       COUNT(DISTINCT CustomerKey_Str) AS DistinctCustomers,
       SUM(Monetary365d) AS SumTrailing365dMonetary,
       AVG(CAST(RecencyDays AS FLOAT)) AS MeanRecency
FROM dbo.FactCustomerSnapshot
WHERE SnapshotDateKey = 20140630
GROUP BY SnapshotDateKey;

SELECT ClusterSegment, COUNT(*) AS Customers,
       SUM(Monetary365d) AS Monetary365dTotal,
       AVG(CAST(RecencyDays AS FLOAT)) AS MeanRecency,
       AVG(CAST(Frequency365d AS FLOAT)) AS MeanFrequency,
       AVG(CAST(Monetary365d AS FLOAT)) AS MeanMonetary
FROM dbo.FactCustomerSnapshot
WHERE SnapshotDateKey = 20140630
GROUP BY ClusterSegment
ORDER BY Customers DESC;

-- 6. Compare snapshot against any live table, to avoid conflating them.
SELECT '20140630 Snapshot' AS Dataset, COUNT(*) AS N,
       SUM(CASE WHEN RecencyDays>100 THEN 1 ELSE 0 END) AS Over100Days
FROM dbo.FactCustomerSnapshot WHERE SnapshotDateKey=20140630
UNION ALL
SELECT 'Purchase-time Live', COUNT(*),
       SUM(CASE WHEN RecencyDays>100 THEN 1 ELSE 0 END)
FROM dbo.FactCustomerRFMLive;

-- 7. Confirm model versions and their effective dates.
SELECT ModelVersion, COUNT(*) AS ClusterRows, MIN(StartDate) AS StartDate,
       MAX(EndDate) AS EndDate, MAX(CONVERT(INT, IsActive)) AS HasActiveCluster
FROM dbo.DimModelConfig
GROUP BY ModelVersion
ORDER BY TRY_CONVERT(INT, ModelVersion);
