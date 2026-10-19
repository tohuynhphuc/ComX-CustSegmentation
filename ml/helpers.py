from datetime import date, timedelta

import mysql.connector
import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler
from sqlalchemy import create_engine
from sqlalchemy.engine import URL
import os
import pyodbc

# ENGINE = create_engine(
#     'mysql+mysqlconnector://root:root@localhost:3306/CompanyX_DW')

# MYSQL_CONFIG = {
#     'host': 'localhost',
#     'port': 3306,
#     'user': 'root',
#     'password': 'root',
#     'database': 'CompanyX_DW',
#     'auth_plugin': 'mysql_native_password',
# }


# SQL Server connection; match SERVER to the "Server name" in SSMS.
# Environment variables let every teammate use their own instance without code edits.
SQLSERVER_SERVER = os.getenv("DW_SQLSERVER_SERVER", "localhost")
SQLSERVER_DATABASE = os.getenv("DW_SQLSERVER_DATABASE", "CompanyX_DataWarehouse")
SQLSERVER_DRIVER = os.getenv("DW_ODBC_DRIVER", "ODBC Driver 18 for SQL Server")
ODBC_CONNECTION_STRING = (
    f"DRIVER={{{SQLSERVER_DRIVER}}};"
    f"SERVER={SQLSERVER_SERVER};"
    f"DATABASE={SQLSERVER_DATABASE};"
    "Trusted_Connection=yes;"
    "Encrypt=yes;"
    "TrustServerCertificate=yes;"
)
ENGINE = create_engine(
    URL.create("mssql+pyodbc", query={"odbc_connect": ODBC_CONNECTION_STRING})
)

RFM_COLS = ["Recency", "Frequency", "Monetary"]
CONFIG_COLS = """
    ModelConfigKey, ModelVersion, ClusterID, ClusterSegment,
    Mean_Scaled_R, Std_Scaled_R, Mean_Scaled_F, Std_Scaled_F, Mean_Scaled_M, Std_Scaled_M,
    Centroid_Scaled_R, Centroid_Scaled_F, Centroid_Scaled_M
"""


# ---------- database ----------


def get_connection():
    return pyodbc.connect(ODBC_CONNECTION_STRING)


def read_sql(query, params=None):
    return pd.read_sql(query, ENGINE, params=params)


def execute_many(sql, rows):
    """One parameterized statement applied to many rows, in one transaction. Returns rows changed."""
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.executemany(sql, rows)
        conn.commit()
        return cur.rowcount
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


# ---------- snapshot extraction ----------


def list_snapshot_dates(year):
    """Every snapshot DateKey in one year. Used by the bootstrap to fill NULL segments, not for training."""
    df = read_sql(
        """
        SELECT DISTINCT SnapshotDateKey AS DateKey
        FROM dbo.FactCustomerSnapshot
        WHERE SnapshotDateKey / 10000 = ?
        ORDER BY DateKey
        """,
        (year,),
    )
    return [int(k) for k in df["DateKey"]]


def extract_snapshot(date_key):
    """RFM rows for one snapshot DateKey, e.g. 20141231."""
    df = read_sql(
        """
        SELECT CustomerKey_Str AS CustomerKey,
               RecencyDays AS Recency,
               Frequency365d AS Frequency,
               Monetary365d AS Monetary
        FROM dbo.FactCustomerSnapshot
        WHERE SnapshotDateKey = ?
        """,
        (date_key,),
    )
    print(f"  Extracted {len(df)} snapshot rows for {date_key}.")
    return df


# ---------- cleaning and scaling ----------


def clean_rfm(df):
    """Deduplicate and clip. Missing RFM is an ETL problem, so raise instead of guessing a value."""
    df = df.drop_duplicates(subset=["CustomerKey"]).copy()
    for col in RFM_COLS:
        df[col] = pd.to_numeric(df[col], errors="coerce").astype(float)
    missing = df[RFM_COLS].isnull().any(axis=1)
    if missing.any():
        raise ValueError(
            f"{int(missing.sum())} rows have NULL RFM values. Fix this in the ETL."
        )
    df["Recency"] = df["Recency"].clip(lower=0)
    df["Frequency"] = df["Frequency"].clip(lower=0)
    df["Monetary"] = df["Monetary"].clip(lower=0)
    return df.reset_index(drop=True)


def to_log_matrix(df):
    """log1p on R, F, M. This is the input to StandardScaler in both training and scoring."""
    return np.log1p(df[RFM_COLS].to_numpy(dtype=float))


def build_scaler(mean, std):
    """Rebuild a fitted StandardScaler from the statistics stored in DimModelConfig."""
    scaler = StandardScaler()
    scaler.mean_ = np.asarray(mean, dtype=float)
    scaler.scale_ = np.asarray(std, dtype=float)
    scaler.var_ = scaler.scale_**2
    scaler.n_features_in_ = len(RFM_COLS)
    return scaler


# model config: read all the columns from the newest version
def fetch_config_by_version(model_version):
    """All cluster rows of one ModelVersion. Used for scoring only, never for training."""
    cfg = read_sql(
        f"SELECT {CONFIG_COLS} FROM dbo.DimModelConfig WHERE ModelVersion = ? ORDER BY ClusterID",
        (str(model_version),),
    )
    if cfg.empty:
        raise RuntimeError(f"No DimModelConfig rows for ModelVersion {model_version}.")
    for col in cfg.columns:
        if col not in ("ClusterSegment", "ModelVersion", "ModelConfigKey", "ClusterID"):
            cfg[col] = pd.to_numeric(cfg[col]).astype(float)
    cfg["ModelConfigKey"] = cfg["ModelConfigKey"].astype(int)
    cfg["ClusterID"] = cfg["ClusterID"].astype(int)
    return cfg


# Take mean, std, centroids for training
def config_arrays(cfg):
    """(mean, std, centroids) of one version. Mean and std repeat on every cluster row."""
    first = cfg.iloc[0]
    mean = [first["Mean_Scaled_R"], first["Mean_Scaled_F"], first["Mean_Scaled_M"]]
    std = [first["Std_Scaled_R"], first["Std_Scaled_F"], first["Std_Scaled_M"]]
    centroids = cfg[
        ["Centroid_Scaled_R", "Centroid_Scaled_F", "Centroid_Scaled_M"]
    ].to_numpy(dtype=float)
    return mean, std, centroids


# ---------- scoring ----------
def assign_clusters(X, centroids):
    """Nearest centroid by Euclidean distance. The same rule KMeans.predict uses."""
    dist = np.linalg.norm(X[:, None, :] - centroids[None, :, :], axis=2)
    return dist.argmin(axis=1)


def score_frame(df_clean, cfg):
    """Label each customer using only the stored parameters of one version."""
    mean, std, centroids = config_arrays(cfg)
    X = build_scaler(mean, std).transform(to_log_matrix(df_clean))
    picked = cfg.iloc[assign_clusters(X, centroids)].reset_index(drop=True)
    return pd.DataFrame(
        {
            "CustomerKey": df_clean["CustomerKey"].values,
            "ModelConfigKey": picked["ModelConfigKey"].values,
            "ClusterSegment": picked["ClusterSegment"].values,
        }
    )


# ---------- model config: write ----------
def insert_model_version(scaler, centroids, mapping, valid_from):
    """
    SCD2 write of one model version.
    valid_from is the first day the version classifies. The previous active version ends the day before.
    Returns the new ModelVersion number.
    """
    mean, std = scaler.mean_, scaler.scale_
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT COUNT(*) FROM dbo.DimModelConfig WHERE StartDate = ?", (valid_from,)
        )

        if cur.fetchone()[0] > 0:
            raise RuntimeError(
                f"A model version already starts on {valid_from}. Refusing to write twice."
            )

        cur.execute(
            "SELECT COALESCE(MAX(TRY_CONVERT(INT, ModelVersion)), 0) + 1 FROM dbo.DimModelConfig"
        )
        new_version = int(cur.fetchone()[0])

        cur.execute(
            "UPDATE dbo.DimModelConfig SET IsActive = 0, EndDate = ? WHERE IsActive = 1",
            (valid_from - timedelta(days=1),),
        )

        insert = """
        INSERT INTO dbo.DimModelConfig
            (ModelVersion, ClusterID, ClusterSegment,
             Mean_Scaled_R, Std_Scaled_R, Mean_Scaled_F, Std_Scaled_F, Mean_Scaled_M, Std_Scaled_M,
             Centroid_Scaled_R, Centroid_Scaled_F, Centroid_Scaled_M,
             IsActive, StartDate)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
        """
        rows = [
            (
                str(new_version),
                int(cid),
                mapping[cid],
                float(mean[0]),
                float(std[0]),
                float(mean[1]),
                float(std[1]),
                float(mean[2]),
                float(std[2]),
                float(centroids[cid][0]),
                float(centroids[cid][1]),
                float(centroids[cid][2]),
                valid_from,
            )
            for cid in sorted(mapping)
        ]
        cur.executemany(insert, rows)
        conn.commit()
        return new_version
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()
