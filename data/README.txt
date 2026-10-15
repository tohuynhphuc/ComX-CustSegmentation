SYNTHETIC CUSTOMER SEGMENTATION DATA WAREHOUSE

Row counts (excluding headers):
DimDate: 365
DimProduct: 120
DimCustomer: 180
FactSales: 1632
DimCustomerProfile: 150

All data is synthetic. Schema transcribed from image(7).png. Column names and order preserved. CSV: UTF-8, comma delimiter, header row, CRLF line endings, no BOM. Money uses decimal point, two decimal places, and assumed USD.

Import the four dimensions first, then FactSales.

Foreign keys:
FactSales.ProductKey -> DimProduct.ProductKey
FactSales.CustomerKey -> DimCustomer.SurrogateKey (NOT natural CustomerKey)
FactSales.OrderDateKey -> DimDate.DateKey
FactSales.ProfileKey -> DimCustomerProfile.ProfileKey

The diagram mixes string fact keys with integer dimension keys for OrderDateKey and ProfileKey. CSV has no types; configure both ends as INT when importing, or cast the fact strings when joining. Keep customer keys as strings.

DimCustomer: 150 distinct customers, including 30 with two historical versions (180 rows). EndDate is EXCLUSIVE: StartDate <= order date < EndDate. Current EndDate=9999-12-31. isActivate spelling retained from diagram; 1 means current. Facts reference the version valid on their order date. Gender uses M/F; MaritalStatus uses M/S; YearlyIncome is an annual USD band. These are assumed allowed values because the image does not list actual CHECK constraints.

DimDate: all 365 days of 2025. DateKey=YYYYMMDD, English day/month names, Year=2025, Quarter=Q1..Q4.

FactSales grain: one single-product completed order per SalesID; OrderQty is quantity and TotalSpent is the whole order total after a synthetic 0/5/10 percent discount, excluding tax and shipping. Product prices are fixed synthetic values per product, not extra schema columns.

Profiles: one year-end snapshot per natural customer as of 2025-12-31. All sales for that customer link to that same retrospective profile. Recency = calendar days since latest order; Frequency = count of SalesID in 2025; Monetary = sum of TotalSpent in 2025 across all customer versions. These are year-end reporting profiles, NOT profiles known at the time of each sale; do not use them as historical prediction features. No profile history table or effective dates are present in the provided schema, so no extra SCD Type 4 history table has been invented.

Deterministic demonstration segmentation (not fitted clustering), evaluated in order:
5 Hibernating: Recency > 120
4 At Risk: Recency > 60
1 Champions: Frequency >= 20 and Monetary >= 1000
2 Loyal: Frequency >= 10
3 Developing: remaining customers

Validation passed: >=100 rows per table; unique primary keys; no orphan foreign keys; correct customer version on every sale; one current version per natural customer; adjacent nonoverlapping historical versions; profile frequency and monetary reconcile with facts; every product, customer version and profile referenced.
