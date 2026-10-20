# live_clustering.py
from db import fetch_active_config, fetch_live, write_segments
from model_core import clean_rfm, score_frame


def run():
    # Latest model version from DimModelConfig
    cfg = fetch_active_config()

    # Current RFM rows from DimCustomerRFMLive
    live = fetch_live()

    scored = score_frame(clean_rfm(live), cfg).merge(
        live[['CustomerKey', 'CurrentSegment', 'CurrentModelKey']], on='CustomerKey')

    cur_seg = scored['CurrentSegment'].fillna('')
    cur_key = scored['CurrentModelKey'].fillna(-1).astype(int)
    changed = scored[
        (cur_seg != scored['ClusterSegment'].fillna('')) |
        (cur_key != scored['ModelConfigKey'])
    ]

    rows = [{'customer_key': r.CustomerKey,
             'segment': r.ClusterSegment,
             'model_key': int(r.ModelConfigKey)}
            for r in changed.itertuples(index=False)]
    written = write_segments(rows)

    print(f'Scored {len(scored)} customers. Wrote {written} new or changed segments.')


if __name__ == '__main__':
    run()