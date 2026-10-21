from datetime import date

from helpers import (
    extract_snapshot,
    list_snapshot_dates,
    clean_rfm,
    fetch_config_by_version,
    score_frame,
    execute_many,
    read_sql,
)
from train_model import train_version

# True: fill NULL segments for every month of the scored year (the snapshot stays complete).
# False: fill only the YYYY1231 rows.
SCORE_ALL_MONTHS = True

# (train_year, valid_from, years whose NULL segments this version fills)
BOOTSTRAP_PLAN = [
    (2011, date(2011, 1, 1), [2011]),
    # (2012, date(2013, 1, 1), [2013]),
    # (2013, date(2014, 1, 1), [2014]),
    # (2014, date(2015, 1, 1), []),
]


def guard_bootstrap_empty():
    n = int(read_sql("SELECT COUNT(*) AS n FROM DimModelConfig")["n"][0])
    if n > 0:
        raise RuntimeError(
            "DimModelConfig already has versions. The bootstrap is one-time only."
        )


def dates_to_fill(year):
    if SCORE_ALL_MONTHS:
        return list_snapshot_dates(year)
    return [year * 10000 + 1231]


def fill_null_segments(out, date_key):
    """Write segments only into rows whose ClusterSegment is still NULL."""
    rows = [
        (int(r.ModelConfigKey), r.ClusterSegment, r.CustomerKey, date_key)
        for r in out.itertuples(index=False)
    ]
    changed = execute_many(
        "UPDATE dbo.FactCustomerSnapshot SET ModelConfigKey = ?, ClusterSegment = ? "
        "WHERE CustomerKey_Str = ? AND SnapshotDateKey = ? AND ClusterSegment IS NULL",
        rows,
    )
    print(f"   {date_key}: filled {changed} of {len(rows)} rows.")
    if changed != len(rows):
        print("   Warning: some rows were already labeled and were left unchanged.")


def bootstrap():
    for train_year, valid_from, fill_years in BOOTSTRAP_PLAN:
        version = train_version(train_year, valid_from=valid_from)
        cfg = fetch_config_by_version(version)
        for fill_year in fill_years:
            print(f"Filling {fill_year} with ModelVersion {version}...")
            for date_key in dates_to_fill(fill_year):
                df = clean_rfm(extract_snapshot(date_key))
                fill_null_segments(score_frame(df, cfg), date_key)
    print("Bootstrap finished. The active version is trained on 20141231.")


if __name__ == "__main__":
    # Run once: python bootstrap.py
    bootstrap()
