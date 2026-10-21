# db.py
import pandas as pd
from sqlalchemy import create_engine, text

ENGINE = create_engine(
    'mssql+pyodbc://localhost/CompanyX_DataWarehouse'
    '?driver=ODBC+Driver+18+for+SQL+Server&trusted_connection=yes&TrustServerCertificate=yes',
    fast_executemany=True,
)

LIVE_TABLE = 'dbo.DimCustomerRFMLive'
SEGMENT_COL = 'CustomerSegment'

CFG_COLS = """
    ModelConfigKey, ModelVersion, ClusterID, ClusterSegment,
    Mean_Scaled_R, Std_Scaled_R, Mean_Scaled_F, Std_Scaled_F, Mean_Scaled_M, Std_Scaled_M,
    Centroid_Scaled_R, Centroid_Scaled_F, Centroid_Scaled_M
"""


def fetch_active_config():
    cfg = pd.read_sql(
        f"SELECT {CFG_COLS} FROM dbo.DimModelConfig WHERE IsActive = 1 ORDER BY ClusterID", ENGINE)
    if cfg.empty:
        raise RuntimeError('No active model in DimModelConfig.')
    numeric = [c for c in cfg.columns if c != 'ClusterSegment']
    cfg[numeric] = cfg[numeric].astype(float)       # SQL Server returns DECIMAL as Decimal
    cfg['ModelConfigKey'] = cfg['ModelConfigKey'].astype(int)
    return cfg


def fetch_live():
    return pd.read_sql(f"""
        SELECT CustomerKey, Recency, Frequency, Monetary,
               {SEGMENT_COL} AS CurrentSegment,
               ModelConfigKey AS CurrentModelKey
        FROM {LIVE_TABLE}
    """, ENGINE)


def write_segments(rows):
    """rows: list of dicts with customer_key, segment, model_key. Returns the number written."""
    if not rows:
        return 0
    sql = text(f"""
        UPDATE {LIVE_TABLE}
        SET {SEGMENT_COL}  = :segment,
            ModelConfigKey = :model_key
        WHERE CustomerKey  = :customer_key
    """)
    with ENGINE.begin() as conn:
        conn.execute(sql, rows)
    return len(rows)

# Training functions (extract_snapshot, list_snapshot_dates, fetch_config_by_version,
# insert_model_version) go here as in the previous message.