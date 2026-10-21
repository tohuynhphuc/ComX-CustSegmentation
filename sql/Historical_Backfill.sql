
USE CompanyX_DataWarehouse;
GO

DECLARE @SnapshotDate DATE = '2011-05-31';
DECLARE @LastDate DATE;

SELECT @LastDate = EOMONTH(MAX(OrderDate))
FROM CompanyX.Sales.SalesOrderHeader
WHERE Status = 5;

WHILE @SnapshotDate <= @LastDate
BEGIN
    PRINT CONCAT('Snapshot: ', @SnapshotDate);

    EXEC dbo.usp_AppendMonthlyRFMSnapshot
        @SnapshotDate = @SnapshotDate;

    SET @SnapshotDate =
        EOMONTH(DATEADD(MONTH, 1, @SnapshotDate));
END;
