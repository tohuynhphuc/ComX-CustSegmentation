/*
 ==============================================================================
 CompanyX Data Warehouse - Backfill Snapshots and Sync Live RFM
 Script này thực hiện 2 việc quan trọng:
   1. Chạy vòng lặp tạo snapshot RFM hàng tháng (từ tháng 5/2011 đến tháng 6/2014,
      cộng thêm mốc 31/12/2014) vào bảng dbo.FactCustomerSnapshot.
   2. Đồng bộ kết quả phân cụm Machine Learning mới nhất vào bảng dbo.FactCustomerRFMLive.

 Hướng dẫn sử dụng cho nhóm:
   - Bước 1: Mở SSMS, kết nối vào CompanyX_DataWarehouse.
   - Bước 2: Chạy Phần 1 của file này (tạo snapshot lịch sử 38 tháng).
   - Bước 3: Mở PowerShell, chạy "python ml/bootstrap.py" để huấn luyện mô hình K-Means.
   - Bước 4: Quay lại SSMS, chạy Phần 2 của file này (đồng bộ sang FactCustomerRFMLive).
 ==============================================================================
*/
USE [CompanyX_DataWarehouse];
GO

SET NOCOUNT ON;
GO

PRINT '==================================================';
PRINT 'PHAN 1: TAO SNAPSHOT LICH SU HANG THANG (2011 - 2014)';
PRINT '==================================================';

DECLARE @CurrentDate DATE = '2011-05-31';
DECLARE @EndDate DATE = '2014-06-30';

WHILE @CurrentDate <= @EndDate
BEGIN
    PRINT 'Dang tao snapshot thang: ' + CONVERT(VARCHAR(10), @CurrentDate, 120);
    EXEC dbo.usp_AppendMonthlyRFMSnapshot @SnapshotDate = @CurrentDate;
    SET @CurrentDate = EOMONTH(DATEADD(MONTH, 1, @CurrentDate));
END;

-- Tạo thêm mốc cuối năm 2014 phục vụ Model Version 4
PRINT 'Dang tao snapshot bo sung: 2014-12-31';
EXEC dbo.usp_AppendMonthlyRFMSnapshot @SnapshotDate = '2014-12-31';
GO

PRINT '==================================================';
PRINT 'PHAN 2: DONG BO PHAN KHUC MOI NHAT SANG FACTCUSTOMERRFMLIVE';
PRINT '==================================================';

UPDATE l
SET l.ModelConfigKey = s.ModelConfigKey,
    l.ClusterSegment = s.ClusterSegment
FROM dbo.FactCustomerRFMLive l
INNER JOIN dbo.FactCustomerSnapshot s
    ON s.CustomerKey_Str = l.CustomerKey_Str
   AND s.SnapshotDateKey = (SELECT MAX(SnapshotDateKey) FROM dbo.FactCustomerSnapshot);

PRINT 'Da cap nhat xong phan khuc cho bang FactCustomerRFMLive.';

-- Kiem tra lai so luong khach hang theo tung phan khuc
SELECT ClusterSegment, COUNT(*) AS TotalCustomers
FROM dbo.FactCustomerRFMLive
GROUP BY ClusterSegment
ORDER BY TotalCustomers DESC;
GO
