import os
import sys
import mysql.connector
import pandas as pd
import pyodbc

# Ensure UTF-8 output on Windows consoles
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')


# ==========================================
# 1. DATABASE CONFIGURATIONS
# ==========================================
MYSQL_CONFIG = {
    'host': 'localhost',
    'port': 3306,
    'user': 'root',
    'password': 'root',                 # Update if your MySQL password is different
    'database': 'CompanyX_DW',
    'auth_plugin': 'mysql_native_password'
}

def get_sqlserver_connection():
    """Detects available ODBC driver and connects to CompanyX on SQL Server."""
    drivers = pyodbc.drivers()
    preferred = [
        'ODBC Driver 18 for SQL Server',
        'ODBC Driver 17 for SQL Server',
        'SQL Server'
    ]
    driver = next((d for d in preferred if d in drivers), drivers[0] if drivers else 'SQL Server')
    extra = ";TrustServerCertificate=yes" if '18' in driver else ""
    conn_str = f"DRIVER={{{driver}}};SERVER=localhost;DATABASE=CompanyX;Trusted_Connection=yes{extra};"
    return pyodbc.connect(conn_str)

# Base directories
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'data'))
SQL_FILE = os.path.join(SCRIPT_DIR, 'dw_init.sql')

# Toggle: If True, sets ClusterID and CustomerSegment to NULL so Python ML can calculate them!
# If False, keeps the baseline synthetic values already in DimCustomerProfile.csv
ERASE_ML_COLUMNS = False


def execute_ddl():
    """Connects to MySQL server and creates the CompanyX_DW database and tables."""
    print(f"⏳ Reading DDL script: {SQL_FILE}...")
    with open(SQL_FILE, 'r', encoding='utf-8') as f:
        sql_script = f.read()

    # Connect to MySQL (without database initially, as script creates it)
    conn_params = MYSQL_CONFIG.copy()
    if 'database' in conn_params:
        del conn_params['database']

    conn = mysql.connector.connect(**conn_params)
    cursor = conn.cursor()

    print("🚀 Initializing CompanyX_DW Database and Tables...")
    statements = [stmt.strip() for stmt in sql_script.split(';') if stmt.strip()]
    for stmt in statements:
        cursor.execute(stmt)

    conn.commit()
    cursor.close()
    conn.close()
    print("✅ Database and tables created successfully!")


def import_csv_data():
    """Imports all 6 CSV files into their respective MySQL tables in dependency order."""
    conn = mysql.connector.connect(**MYSQL_CONFIG)
    cursor = conn.cursor()

    # 1. DimProduct
    print("⏳ Importing DimProduct.csv...")
    df_prod = pd.read_csv(os.path.join(DATA_DIR, 'DimProduct.csv'))
    prod_query = """
    INSERT INTO DimProduct (ProductKey, ProductName, Category)
    VALUES (%s, %s, %s)
    """
    cursor.executemany(prod_query, df_prod.values.tolist())
    conn.commit()
    print(f"   Loaded {len(df_prod)} rows into DimProduct.")

    # 2. DimDate
    print("⏳ Importing DimDate.csv...")
    df_date = pd.read_csv(os.path.join(DATA_DIR, 'DimDate.csv'))
    date_query = """
    INSERT INTO DimDate (DateKey, DayName, MonthName, Year, Quarter)
    VALUES (%s, %s, %s, %s, %s)
    """
    cursor.executemany(date_query, df_date.values.tolist())
    conn.commit()
    print(f"   Loaded {len(df_date)} rows into DimDate.")

    # 3. SubDimCustomer
    print("⏳ Importing SubDimCustomer.csv...")
    df_sub = pd.read_csv(os.path.join(DATA_DIR, 'SubDimCustomer.csv'))
    sub_query = """
    INSERT INTO SubDimCustomer (CustomerKey, Gender, MaritalStatus, TotalChildren, HomeOwnerFlag, NumberCarsOwned)
    VALUES (%s, %s, %s, %s, %s, %s)
    """
    cursor.executemany(sub_query, df_sub.values.tolist())
    conn.commit()
    print(f"   Loaded {len(df_sub)} rows into SubDimCustomer.")

    # 4. DimCustomer
    print("⏳ Importing DimCustomer.csv...")
    df_cust = pd.read_csv(os.path.join(DATA_DIR, 'DimCustomer.csv'))
    cust_query = """
    INSERT INTO DimCustomer (SurrogateKey, CustomerKey, BirthDate, Education, Occupation, 
                            YearlyIncome, CountryName, RegionGroup, isActivate, StartDate, EndDate)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    """
    cursor.executemany(cust_query, df_cust.values.tolist())
    conn.commit()
    print(f"   Loaded {len(df_cust)} rows into DimCustomer.")

    # 5. DimCustomerProfile
    print("⏳ Importing DimCustomerProfile.csv...")
    df_prof = pd.read_csv(os.path.join(DATA_DIR, 'DimCustomerProfile.csv'))
    if ERASE_ML_COLUMNS:
        print("   Notice: Setting ClusterID and CustomerSegment to NULL (to be populated by ML script).")
        df_prof['ClusterID'] = None
        df_prof['CustomerSegment'] = None

    prof_query = """
    INSERT INTO DimCustomerProfile (ProfileKey, ClusterID, CustomerSegment, Recency, Frequency, Monetary)
    VALUES (%s, %s, %s, %s, %s, %s)
    """
    # Replace pandas NaN with None so MySQL treats them as SQL NULL
    prof_records = df_prof.where(pd.notnull(df_prof), None).values.tolist()
    cursor.executemany(prof_query, prof_records)
    conn.commit()
    print(f"   Loaded {len(df_prof)} rows into DimCustomerProfile.")

    # 6. FactSales
    print("⏳ Importing FactSales.csv...")
    df_fact = pd.read_csv(os.path.join(DATA_DIR, 'FactSales.csv'))
    fact_query = """
    INSERT INTO FactSales (SalesID, ProductKey, CustomerKey, OrderDateKey, ProfileKey, OrderQty, TotalSpent)
    VALUES (%s, %s, %s, %s, %s, %s, %s)
    """
    cursor.executemany(fact_query, df_fact.values.tolist())
    conn.commit()
    print(f"   Loaded {len(df_fact)} rows into FactSales.")

    cursor.close()
    conn.close()
    print("🎉 All 6 dimension & fact CSV tables imported into CompanyX_DW successfully!")


def populate_fact_customer_snapshot(through_date='2014-12-31', batch_size=10000):
    """
    Extracts monthly RFM snapshots from CompanyX (SQL Server) 
    and batch inserts them into FactCustomerSnapshot (MySQL DW).
    """
    print(f"⏳ Extracting monthly customer snapshots from SQL Server up to {through_date}...")
    sql_query = f"""
    SET NOCOUNT ON;
    WITH MonthEnds AS (
        SELECT CAST('2011-05-31' AS DATE) AS SnapshotDate
        UNION ALL
        SELECT EOMONTH(DATEADD(month, 1, SnapshotDate))
        FROM MonthEnds
        WHERE SnapshotDate < '{through_date}'
    ),
    Snapshots AS (
        SELECT 
            CAST(soh.CustomerID AS VARCHAR(50)) AS CustomerKey,
            CAST(FORMAT(m.SnapshotDate, 'yyyyMMdd') AS INT) AS DateKey,
            DATEDIFF(day, MAX(soh.OrderDate), m.SnapshotDate) AS Recency,
            COUNT(DISTINCT soh.SalesOrderID) AS Frequency,
            CAST(SUM(soh.TotalDue) AS DECIMAL(18, 2)) AS Monetary
        FROM MonthEnds m
        JOIN Sales.SalesOrderHeader soh 
            ON soh.OrderDate <= m.SnapshotDate 
           AND soh.OnlineOrderFlag = 1
        GROUP BY m.SnapshotDate, soh.CustomerID
    )
    SELECT 
        CustomerKey, DateKey, NULL AS ModelConfigKey, NULL AS ClusterProfileKey,
        Recency, Frequency, Monetary, NULL AS ClusterSegment
    FROM Snapshots
    ORDER BY DateKey, CustomerKey
    OPTION (MAXRECURSION 100);
    """
    
    ss_conn = get_sqlserver_connection()
    ss_cursor = ss_conn.cursor()
    ss_cursor.execute(sql_query)
    
    insert_sql = """
    INSERT INTO FactCustomerSnapshot 
        (CustomerKey, DateKey, ModelConfigKey, ClusterProfileKey, Recency, Frequency, Monetary, ClusterSegment)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
    """
    
    my_conn = mysql.connector.connect(**MYSQL_CONFIG)
    my_cursor = my_conn.cursor()
    
    total_inserted = 0
    while True:
        rows = ss_cursor.fetchmany(batch_size)
        if not rows:
            break
        records = [tuple(r) for r in rows]
        my_cursor.executemany(insert_sql, records)
        my_conn.commit()
        total_inserted += len(records)
        print(f"   Inserted {total_inserted:,} rows into FactCustomerSnapshot...")
        
    ss_cursor.close()
    ss_conn.close()
    my_cursor.close()
    my_conn.close()
    print(f"✅ Successfully loaded {total_inserted:,} rows into FactCustomerSnapshot!")


if __name__ == '__main__':
    execute_ddl()
    import_csv_data()
    populate_fact_customer_snapshot()

