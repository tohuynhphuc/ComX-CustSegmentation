import sys
from datetime import date

from sklearn.cluster import KMeans
from sklearn.preprocessing import StandardScaler

from helpers import (RFM_COLS, extract_snapshot, clean_rfm, to_log_matrix, insert_model_version)

BEST_K = 4
SEGMENTS = ['Champions', 'Active', 'At-Risk', 'Lost / Dormant']
FIRST_LIVE_TRAIN_YEAR = 2018      # years before this belong to the bootstrap


def fit_model(df_clean):
    """StandardScaler on log1p(RFM), then K-means on the scaled values."""
    X_log = to_log_matrix(df_clean)
    scaler = StandardScaler().fit(X_log)
    kmeans = KMeans(n_clusters=BEST_K, init='k-means++', n_init=10, max_iter=300, random_state=42)
    labels = kmeans.fit_predict(scaler.transform(X_log))
    return scaler, kmeans, labels


def build_segment_mapping(df_clean):
    """Name each cluster by the composite rank of its raw RFM means."""
    assert len(SEGMENTS) == BEST_K, 'SEGMENTS must have one name per cluster'
    means = df_clean.groupby('ClusterID')[RFM_COLS].mean()
    m_points = means['Monetary'].rank(ascending=True)
    f_points = means['Frequency'].rank(ascending=True)
    r_points = means['Recency'].rank(ascending=False)
    means['CompositeScore'] = m_points + f_points + (r_points * 1.1)

    ordered = means.sort_values(by='CompositeScore', ascending=False).index.tolist()
    mapping = dict(zip(ordered, SEGMENTS))

    print('Composite rank assignments:')
    for cid, name in mapping.items():
        print(f"   Cluster {cid} (score {means.loc[cid, 'CompositeScore']:.1f}) -> {name}")
    return mapping


def train_version(train_year, valid_from=None):
    """
    Fit on the YEAR1231 snapshot and write one version to DimModelConfig.
    By default the version starts on 1 January of the following year.
    Returns the new ModelVersion number.
    """
    year_end = train_year * 10000 + 1231
    if valid_from is None:
        valid_from = date(train_year + 1, 1, 1)

    df_raw = extract_snapshot(year_end)
    if df_raw.empty:
        raise RuntimeError(f'No snapshot rows for DateKey {year_end}. Run the ETL first.')

    df_clean = clean_rfm(df_raw)
    scaler, kmeans, labels = fit_model(df_clean)
    df_clean['ClusterID'] = labels

    mapping = build_segment_mapping(df_clean)
    version = insert_model_version(scaler, kmeans.cluster_centers_, mapping, valid_from)
    print(f'Saved ModelVersion {version}: trained on {year_end}, valid from {valid_from}.')
    return version


if __name__ == '__main__':
    # Year-end job, for example: python train_model.py 2018   (trains on 20181231)
    year = int(sys.argv[1])
    if year < FIRST_LIVE_TRAIN_YEAR:
        raise SystemExit(f'Years before {FIRST_LIVE_TRAIN_YEAR} are handled by bootstrap.py.')
    train_version(year)