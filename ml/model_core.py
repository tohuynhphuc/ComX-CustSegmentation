# model_core.py
import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler

RFM_COLS = ['Recency', 'Frequency', 'Monetary']


def clean_rfm(df):
    df = df.drop_duplicates(subset=['CustomerKey']).copy()
    for col in RFM_COLS:
        df[col] = pd.to_numeric(df[col], errors='coerce').astype(float)
    missing = df[RFM_COLS].isnull().any(axis=1)
    if missing.any():
        raise ValueError(f'{int(missing.sum())} rows have NULL RFM values. Fix this in the ETL.')
    for col in RFM_COLS:
        df[col] = df[col].clip(lower=0)
    return df.reset_index(drop=True)


def to_log_matrix(df):
    return np.log1p(df[RFM_COLS].to_numpy(dtype=float))


def build_scaler(mean, std):
    scaler = StandardScaler()
    scaler.mean_ = np.asarray(mean, dtype=float)
    scaler.scale_ = np.asarray(std, dtype=float)
    scaler.var_ = scaler.scale_ ** 2
    scaler.n_features_in_ = len(RFM_COLS)
    return scaler


def assign_clusters(X, centroids):
    dist = np.linalg.norm(X[:, None, :] - centroids[None, :, :], axis=2)
    return dist.argmin(axis=1)


def score_frame(df_clean, cfg):
    first = cfg.iloc[0]
    mean = first[['Mean_Scaled_R', 'Mean_Scaled_F', 'Mean_Scaled_M']].to_numpy(float)
    std = first[['Std_Scaled_R', 'Std_Scaled_F', 'Std_Scaled_M']].to_numpy(float)
    centroids = cfg[['Centroid_Scaled_R', 'Centroid_Scaled_F', 'Centroid_Scaled_M']].to_numpy(float)
    X = build_scaler(mean, std).transform(to_log_matrix(df_clean))
    picked = cfg.iloc[assign_clusters(X, centroids)].reset_index(drop=True)
    return pd.DataFrame({
        'CustomerKey': df_clean['CustomerKey'].values,
        'ModelConfigKey': picked['ModelConfigKey'].values,
        'ClusterSegment': picked['ClusterSegment'].values,
    })