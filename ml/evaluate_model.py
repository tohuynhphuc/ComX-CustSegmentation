"""Read-only evaluation of the existing saved RFM K-Means model.

Run from the ml directory, with this file placed beside helpers.py:
    python evaluate_model.py

Evaluation A: clustering quality for 2013-12-31 and 2014-06-30.
Evaluation B: business backtest: predict Jan-Jun 2014 customer purchases
from segments assigned using RFM available on 2013-12-31 only.
"""

import numpy as np
import pandas as pd
from sklearn.metrics import (
    calinski_harabasz_score,
    davies_bouldin_score,
    silhouette_score,
)

from ml.model_core import (
    assign_clusters,
    build_scaler,
    clean_rfm,
    config_arrays,
    extract_snapshot,
    fetch_config_by_version,
    read_sql,
    to_log_matrix,
)

MODEL_VERSION = 1
TRAIN_DATE_KEY = 20131231
TEST_DATE_KEY = 20140630


def score_and_measure(date_key, cfg):
    df = clean_rfm(extract_snapshot(date_key))
    mean, std, centroids = config_arrays(cfg)
    X = build_scaler(mean, std).transform(to_log_matrix(df))
    assignments = assign_clusters(X, centroids)
    if len(np.unique(assignments)) < 2:
        raise RuntimeError(
            "Only one cluster received customers; metrics are undefined."
        )

    scored = df.copy()
    scored["Segment"] = cfg.iloc[assignments]["ClusterSegment"].to_numpy()
    print(f"\n=== Clustering quality: {date_key} ===")
    print(f"Customers: {len(df):,}")
    print(
        "Silhouette (sample 2,000): "
        f"{silhouette_score(X, assignments, sample_size=min(2000, len(X)), random_state=42):.4f}"
    )
    print(f"Davies-Bouldin:          {davies_bouldin_score(X, assignments):.4f}")
    print(f"Calinski-Harabasz:       {calinski_harabasz_score(X, assignments):.2f}")
    profiles = scored.groupby("Segment", sort=True).agg(
        Customers=("CustomerKey", "size"),
        AvgRecency=("Recency", "mean"),
        AvgFrequency=("Frequency", "mean"),
        AvgMonetary=("Monetary", "mean"),
    )
    print("\nSegment RFM profiles:")
    print(profiles.round(2).to_string())
    return scored


def forward_business_backtest(baseline_scored):
    """Actual Jan-Jun 2014 orders for the customers scored as of Dec 2013.

    This intentionally does NOT use June 2014 features to predict
    January-June 2014 purchases, which would leak the outcome into the input.
    """
    future = read_sql("""
        SELECT CONVERT(NVARCHAR(20), h.CustomerID) AS CustomerKey,
               COUNT(DISTINCT h.SalesOrderID) AS FutureOrders,
               SUM(CAST(d.LineTotal AS DECIMAL(19,4))) AS FutureRevenue
        FROM CompanyX.Sales.SalesOrderHeader AS h
        JOIN CompanyX.Sales.SalesOrderDetail AS d
          ON d.SalesOrderID = h.SalesOrderID
        WHERE h.OrderDate >= '2014-01-01'
          AND h.OrderDate <  '2014-07-01'
          AND h.Status = 5
        GROUP BY h.CustomerID
        """)
    future["CustomerKey"] = future["CustomerKey"].astype(str)
    frame = baseline_scored[["CustomerKey", "Segment"]].copy()
    frame["CustomerKey"] = frame["CustomerKey"].astype(str)
    frame = frame.merge(future, on="CustomerKey", how="left", validate="one_to_one")
    frame["FutureOrders"] = frame["FutureOrders"].fillna(0).astype(int)
    frame["FutureRevenue"] = pd.to_numeric(
        frame["FutureRevenue"], errors="coerce"
    ).fillna(0.0)
    frame["PurchasedNext6M"] = (frame["FutureOrders"] > 0).astype(int)

    overall_purchase_rate = frame["PurchasedNext6M"].mean()
    by_segment = frame.groupby("Segment", sort=True).agg(
        Customers=("CustomerKey", "size"),
        RepeatPurchaseRate=("PurchasedNext6M", "mean"),
        AvgFutureOrders=("FutureOrders", "mean"),
        AvgFutureRevenue=("FutureRevenue", "mean"),
    )
    by_segment["RepeatPurchaseRate"] *= 100
    by_segment["PurchaseRateLift"] = (
        by_segment["RepeatPurchaseRate"] / (overall_purchase_rate * 100)
        if overall_purchase_rate > 0
        else np.nan
    )
    print("\n=== Forward business backtest: 2014-01-01 to 2014-06-30 ===")
    print(
        "Segment customers with *2013-12-31* RFM only; check purchases AFTER that date."
    )
    print(f"Overall six-month purchase rate: {overall_purchase_rate:.2%}")
    print(by_segment.round(2).to_string())
    print(
        "\nRepeatPurchaseRate is a percentage; PurchaseRateLift = segment rate / overall rate."
    )
    print(
        "These measure business usefulness, not classification accuracy or causality."
    )
    print(
        "Order statuses are included as in the current RFM SQL. Filter cancellations if needed."
    )


def main():
    cfg = fetch_config_by_version(MODEL_VERSION)
    baseline = score_and_measure(TRAIN_DATE_KEY, cfg)
    score_and_measure(TEST_DATE_KEY, cfg)
    forward_business_backtest(baseline)


if __name__ == "__main__":
    main()
