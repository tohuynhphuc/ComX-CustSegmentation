# CompanyX — Customer Segmentation & Business Intelligence

A customer-focused Business Intelligence system built with **SQL Server**, **SQL Server Integration Services (SSIS)**, **Python / K-Means**, and **Power BI**. The system maintains customer profiles, calculates Recency–Frequency–Monetary (RFM) features, assigns five customer segments, and records monthly snapshots for historical analysis.

## Project overview

| Component | Purpose |
| --- | --- |
| `CompanyX` (source database) | Original customer and sales transactions |
| `CompanyX_DataWarehouse` | Customer dimensions, SCD history, model configurations, live RFM and monthly RFM snapshots |
| SSIS customer package | Incrementally loads customer demographics with SCD Type 0/1/2 handling and T-SQL `MERGE` |
| SSIS live RFM package + Python | Refreshes purchase-time RFM and scores customers with the latest active K-Means model |
| SSIS monthly snapshot package | Captures month-end RFM and assigns historical segments |
| Python training scripts | Train five-cluster K-Means models and save model versions in SQL Server |
| Power BI | Customer, demographic, segmentation and business analysis dashboards |

**Two RFM views serve different purposes:** `FactCustomerRFMLive` stores values evaluated at each customer's latest purchase and is refreshed after relevant sales changes. `FactCustomerSnapshot` evaluates customers at each month-end, allowing inactivity and segment changes to be examined over time. The Power BI report currently uses the **2014-06-30 snapshot** as its main customer-analysis reference.

## Requirements

- SQL Server with **SQL Server Agent**, SQL Server Management Studio (SSMS), and permission to deploy SSIS packages to **Integration Services Catalogs (`SSISDB`)**.
- Visual Studio with the **SQL Server Integration Services Projects** extension.
- **Microsoft OLE DB Driver for SQL Server** for the SSIS connection managers.
- Python with `pandas`, `numpy`, `scikit-learn`, `SQLAlchemy`, `pyodbc` and `matplotlib`; **ODBC Driver 18 for SQL Server**.
- Power BI Desktop to open the dashboard (optional for running the ETL itself).
- The original `CompanyX` database backup provided for the course.

The project uses **Windows Authentication** and, by default, SQL Server at `localhost`. If your server/instance or project location differs, update the SSIS connection managers and Python paths before running anything.

## Setup: first run from an empty warehouse

> **Important:** This order matters. **Customer profiles and historical snapshots must exist before the first model can be trained.** The two warehouse setup scripts create objects; they do **not** erase an existing warehouse. For a genuinely fresh start, first back up and remove/rename an old `CompanyX_DataWarehouse` (or use a separate SQL Server instance). Do not delete the source `CompanyX` database.

### 1. Restore the source database

Restore the provided **`CompanyX`** database in SSMS, as demonstrated in class. Make sure it is named `CompanyX` and contains the expected `Sales` tables and views.

### 2. Create the Data Warehouse tables

In SSMS, execute:

```text
sql/01_CreateTables.sql
```

This creates `CompanyX_DataWarehouse` if necessary, then creates its dimensions, facts, staging table, constraints and date records.

### 3. Create the procedures and functions

Execute:

```text
sql/02_CreateRoutines.sql
```

The project is now ready to load customer records and generate RFM data. You do **not** need to execute the older individual SQL definition files.

### 4. Load customer profiles once (required before historical RFM)

1. Open `CompanyX_CustomerSegmentation/CompanyX_CustomerSegmentation.sln` in Visual Studio.
2. In the `ETL_Pipeline` project, inspect/test the connections to both `CompanyX` and `CompanyX_DataWarehouse`. Check any server names or credentials inherited from another laptop.
3. Run **`Package_Customer_Incremental.dtsx`** once from Visual Studio.
4. Confirm that `dbo.DimCustomerProfiling` and `dbo.DimClusterProfiling` have rows.

Do not run `RFM_Live.dtsx` yet: its Python scoring task requires a trained model.

### 5. Initialize historical monthly snapshots (required before model training)

In SSMS, execute the existing one-time backfill script:

```text
sql/Historical_Backfill.sql
```

It runs `usp_AppendMonthlyRFMSnapshot` for each month from **May 2011 through the last sales month** (June 2014 in the course dataset). The procedure avoids inserting duplicate customer/month records.

Verify that `dbo.FactCustomerSnapshot` contains at least the **2011-12-31**, **2012-12-31**, and **2013-12-31** snapshots. The training scripts read those year-end records; simply creating an empty fact table is not sufficient.

Do **not** use `sql/CustomerSnapshot_RFM_Backfill.sql` for this setup: it includes older warehouse-alteration/procedure definitions rather than just running the historical backfill.

### 6. Set up Python and train the three model versions

From the project root in PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install pandas numpy scikit-learn SQLAlchemy pyodbc matplotlib
```

Check the connection in **`ml/db.py`** (currently hardcoded to `localhost/CompanyX_DataWarehouse`). The training code also has connection defaults in `ml/model_core.py`; if you use a different SQL Server instance, make sure **both** connect to the same warehouse. With the default `localhost` setup, no changes are necessary.

From the `ml` directory, run the scripts **in this order**:

```powershell
cd ml
python bootstrap.py
python train_model.py 2012
python train_model.py 2013
```

- `bootstrap.py` creates the **2011** baseline model and labels 2011 historical snapshots.
- The subsequent commands create models trained on the **2012** and **2013** year-end snapshots.
- **No 2014 model is trained** because the available source sales end in June 2014.
- Each model contains **five clusters**. On a clean run, `DimModelConfig` should contain **three model versions (15 rows total)**, with the 2013-trained version active from January 2014.

**Bootstrap is a one-time initialization step.** Do not rerun it after models have been created; it intentionally refuses to run when `DimModelConfig` is non-empty.

### 7. Classify the remaining historical snapshots

After training, execute in SSMS:

```sql
USE CompanyX_DataWarehouse;
GO
EXEC dbo.usp_ValidateRFMModels;
EXEC dbo.usp_ClusterCustomerRFMSnapshot;
GO
```

This assigns effective-dated model versions and segment labels to historical snapshot rows that still need classification. The 2011 labels were already filled by `bootstrap.py`.

### 8. Test the live RFM pipeline

In Visual Studio, open **`RFM_Live.dtsx`**:

1. Confirm its warehouse connection.
2. **Update the `Score Live Customers` Execute Process task** to point to the Python executable and `ml/live_clustering.py` on **your** laptop. Its committed executable, arguments and working-directory paths are machine-specific.
3. Run `RFM_Live.dtsx` once. It first calls `usp_RefreshCustomerRFMLive`, then runs the enabled Python scoring task.
4. Check `dbo.FactCustomerRFMLive` for populated RFM values and segments.

The SQL-based `Cluster Customer` task in this package is **disabled**; Python is the intended live scorer. The Python scorer currently **scores all live rows but writes back only new/changed assignments**. Its existence should not be confused with recalculating every customer's *RFM from source transactions* after each purchase.

### 9. Deploy the SSIS project

Build `ETL_Pipeline` in Visual Studio and deploy it to the SQL Server **Integration Services Catalog (`SSISDB`)**. Confirm the deployed package connections and that the SQL Server Agent execution identity can access the warehouse, Python executable and script paths. If Windows Authentication works interactively but fails in a job, inspect the SQL Agent service account/proxy permissions.

Deploy these three packages:

```text
Package_Customer_Incremental.dtsx
RFM_Live.dtsx
RFM_Snapshot.dtsx
```

### 10. Create two SQL Server Agent jobs

Under **SQL Server Agent → Jobs**, create the following:

| Job | Job steps (in this order) | Schedule |
| --- | --- | --- |
| **Customer + Live RFM** | **1.** Execute deployed `Package_Customer_Incremental.dtsx` **2.** On success, execute deployed `RFM_Live.dtsx` | Every **1 minute** |
| **Monthly RFM Snapshot** | Execute deployed `RFM_Snapshot.dtsx` | **1st day of each month, 12:05 AM (00:05)** |

Use **SQL Server Integration Services Package** job steps with the deployed `SSIS Catalog` packages. The first job must advance from Step 1 to Step 2 **only on success**; failures should stop the job and be visible in job history. Ensure SQL Server Agent is running and both jobs are enabled.

`RFM_Snapshot.dtsx` computes the **previous month's end date** and then classifies unassigned snapshot rows. Thus a run at 00:05 on November 1 creates the **October 31** snapshot. Historical backfill from Step 5 is separate from this ongoing schedule.

### 11. Start and verify

Start each job manually once using **Start Job at Step...** and review its history. After successful runs, leave both schedules enabled. Example SSMS checks:

```sql
USE CompanyX_DataWarehouse;
GO

SELECT 'Customer profiles' AS Item, COUNT(*) AS RowCount FROM dbo.DimCustomerProfiling
UNION ALL SELECT 'Customer profile history', COUNT(*) FROM dbo.DimClusterProfiling
UNION ALL SELECT 'Monthly snapshot rows', COUNT(*) FROM dbo.FactCustomerSnapshot
UNION ALL SELECT 'Model configuration rows', COUNT(*) FROM dbo.DimModelConfig
UNION ALL SELECT 'Live RFM rows', COUNT(*) FROM dbo.FactCustomerRFMLive;

SELECT ModelVersion, MIN(StartDate) AS ValidFrom,
       MAX(EndDate) AS ValidThrough, MAX(CAST(IsActive AS INT)) AS IsActive,
       COUNT(*) AS Clusters
FROM dbo.DimModelConfig
GROUP BY ModelVersion
ORDER BY ModelVersion;

SELECT SnapshotDateKey, COUNT(*) AS Customers,
       SUM(CASE WHEN ClusterSegment IS NULL THEN 1 ELSE 0 END) AS Unclassified
FROM dbo.FactCustomerSnapshot
GROUP BY SnapshotDateKey
ORDER BY SnapshotDateKey;

SELECT COUNT(*) AS UnclassifiedLiveRows
FROM dbo.FactCustomerRFMLive
WHERE ClusterSegment IS NULL OR ModelConfigKey IS NULL;
```

Once the two jobs run successfully, **customer and live RFM processing (every minute)** and **monthly snapshots (at 00:05 on the 1st)** are automated. Reopen/refresh the Power BI report at `PowerBI/BI_CUSTOMER_SEGMENTATION_FINAL.pbix` to verify its connection and displayed data; its current primary analytical population is the June 30, 2014 snapshot.

## Annual model retraining (separate from the two SQL Agent jobs)

The repository also includes `dags/ml_customer_segmentation_dag.py` for annual model training via **Apache Airflow**. **Deploying the SSIS project and enabling the two SQL Server Agent jobs does not enable this DAG.** Airflow must be installed/configured, the DAG's machine-specific `ML_DIR`/Python import paths must be corrected, and its schedule must run **after the year-end snapshot has completed successfully**. The committed DAG's scheduled end-to-end execution has not yet been verified.

For the course's historical data, Steps 5–7 manually initialize the three available training years; they do not require Airflow. For future automated retraining, verify the Airflow-to-SSIS dependency and test a complete year-end run before claiming that annual retraining is operational.

## Repository layout

```text
CompanyX_CustomerSegmentation/  # Visual Studio solution and SSIS project
sql/                            # Warehouse creation, routines, historical backfill
ml/                             # Model training, bootstrap, scoring and plots
dags/                           # Annual Airflow DAG
PowerBI/                        # Power BI dashboard and exported documentation
document/                       # LaTeX project report
README.md                       # This setup guide
```

## Common setup problems

- **`bootstrap.py` reports no rows for 20111231:** load the customer dimensions (Step 4), then backfill historical snapshots (Step 5) before training.
- **A model version already exists:** do not rerun the bootstrap or the same annual training on a populated model table.
- **SSIS works in Visual Studio but fails under SQL Server Agent:** confirm the deployed connections, Agent credentials, file permissions and Execute Process Python paths.
- **Python connects to the wrong server/database:** check `ml/db.py` as well as `ml/model_core.py`.
- **The monthly job doesn't produce 2011–2014 history:** that's expected; it only handles the previous month. Use `sql/Historical_Backfill.sql` for the one-time historical load.

**Deployment scope:** local SQL Server + SSIS + Python + Power BI. Online hosting is not included in the completed setup.
