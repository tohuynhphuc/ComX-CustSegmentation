"""RFM K-Means evaluation and visualization.

Run:
    python plot_rfm_diagnostics.py

Or for another snapshot:
    python plot_rfm_diagnostics.py --snapshot 20140630

All plots are saved in the plots/ directory.
This script does not modify the database.
"""

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_samples, silhouette_score
from sklearn.preprocessing import StandardScaler

from helpers import (
    extract_snapshot,
    clean_rfm,
    to_log_matrix,
    fetch_config_by_version,
    config_arrays,
    build_scaler,
    assign_clusters,
)

RANDOM_STATE = 42
BEST_K = 5


# ---------- Data preparation ----------


def get_scaled_rfm(snapshot_key):
    """Extract, clean, log-transform, and scale RFM values."""

    raw = extract_snapshot(snapshot_key)

    if raw.empty:
        raise ValueError(f"Snapshot {snapshot_key} contains no records.")

    clean = clean_rfm(raw)

    X = StandardScaler().fit_transform(to_log_matrix(clean))

    return clean, X


# ---------- K-Means ----------


def fit_kmeans(X, k):
    """Train temporary K-Means for evaluation."""

    model = KMeans(
        n_clusters=k,
        init="k-means++",
        n_init=10,
        max_iter=300,
        random_state=RANDOM_STATE,
    )

    model.fit(X)

    return model


# ---------- PCA Visualization ----------


def plot_clusters_pca(X, labels, names, path):
    """Project scaled RFM data to 2D using PCA."""

    pca = PCA(n_components=2, random_state=RANDOM_STATE)

    coords = pca.fit_transform(X)

    var = pca.explained_variance_ratio_ * 100

    cmap = plt.get_cmap("viridis", len(names))

    fig, ax = plt.subplots(figsize=(9, 7))

    for i, cid in enumerate(sorted(names)):

        mask = labels == cid

        ax.scatter(
            coords[mask, 0],
            coords[mask, 1],
            s=8,
            alpha=0.5,
            color=cmap(i),
            rasterized=True,
            label=(f"{names[cid]} " f"(cluster {cid}; n={mask.sum():,})"),
        )

    ax.set_xlabel(f"Principal Component 1 " f"({var[0]:.1f}% variance)")

    ax.set_ylabel(f"Principal Component 2 " f"({var[1]:.1f}% variance)")

    ax.set_title(f"Customer clusters (PCA 2D), K = {len(names)}")

    ax.legend(markerscale=2, fontsize=9)

    ax.grid(alpha=0.15)

    fig.tight_layout()

    fig.savefig(path, dpi=300, bbox_inches="tight")

    plt.close(fig)


# ---------- Main evaluation ----------


def make_plots(snapshot_key, max_k, detail_k, sample_size, output_dir, model_version):

    clean, X = get_scaled_rfm(snapshot_key)

    n = len(X)

    if n < 3:
        raise ValueError("At least 3 customers are required.")

    if not (2 <= detail_k <= max_k < n):
        raise ValueError("Require 2 <= detail_k <= max_k " "< number of customers.")

    if sample_size < 3:
        raise ValueError("Sample size must be at least 3.")

    output_dir.mkdir(parents=True, exist_ok=True)

    # Use the same customer sample for all K values.
    sample_idx = np.random.RandomState(RANDOM_STATE).permutation(n)[
        : min(sample_size, n)
    ]

    X_sample = X[sample_idx]

    results = []
    labels_for_detail = None

    # ---------- Evaluate different K ----------

    for k in range(1, max_k + 1):

        model = fit_kmeans(X, k)

        score = np.nan

        if k >= 2:

            sample_labels = model.labels_[sample_idx]

            n_sample_clusters = np.unique(sample_labels).size

            if 1 < n_sample_clusters < len(sample_labels):

                score = silhouette_score(X_sample, sample_labels)

        if k == detail_k:
            labels_for_detail = model.labels_[sample_idx].copy()

        results.append(
            {
                "K": k,
                "Inertia": model.inertia_,
                "Silhouette": score,
            }
        )

        print(
            f"K={k:>2} "
            f"inertia={model.inertia_:>12,.2f}"
            + (f"  silhouette={score:.4f}" if np.isfinite(score) else "")
        )

    scores = pd.DataFrame(results)

    csv_path = output_dir / f"kmeans_scores_{snapshot_key}.csv"

    scores.to_csv(csv_path, index=False, float_format="%.6f")

    # ---------- Plot 1: Elbow ----------

    fig, ax = plt.subplots(figsize=(9, 5.5))

    ax.plot(scores["K"], scores["Inertia"], marker="o", linewidth=2)

    ax.axvline(
        detail_k,
        linestyle="--",
        linewidth=1.2,
        alpha=0.55,
        label=f"Current model: K={detail_k}",
    )

    ax.set_title(f"Elbow Method — RFM snapshot {snapshot_key}")

    ax.set_xlabel("Number of clusters (K)")

    ax.set_ylabel("Inertia (within-cluster sum of squares)")

    ax.set_xticks(scores["K"])

    ax.grid(alpha=0.25)
    ax.legend()

    fig.tight_layout()

    elbow_path = output_dir / f"elbow_{snapshot_key}.png"

    fig.savefig(elbow_path, dpi=170, bbox_inches="tight")

    plt.close(fig)

    # ---------- Plot 2: Silhouette vs K ----------

    valid = scores.dropna(subset=["Silhouette"])

    fig, ax = plt.subplots(figsize=(9, 5.5))

    ax.plot(valid["K"], valid["Silhouette"], marker="o", linewidth=2)

    ax.axvline(
        detail_k,
        linestyle="--",
        linewidth=1.2,
        alpha=0.55,
        label=f"Current model: K={detail_k}",
    )

    if detail_k in valid["K"].values:

        val = float(valid.loc[valid["K"] == detail_k, "Silhouette"].iloc[0])

        ax.annotate(
            f"K={detail_k}: {val:.3f}",
            xy=(detail_k, val),
            xytext=(9, 12),
            textcoords="offset points",
        )

    ax.set_title(f"Silhouette Score vs K — " f"RFM snapshot {snapshot_key}")

    ax.set_xlabel("Number of clusters (K)")

    ax.set_ylabel(f"Mean silhouette score " f"(sample of {len(X_sample):,} customers)")

    ax.set_xticks(valid["K"])

    ax.set_ylim(
        min(-0.05, valid["Silhouette"].min() - 0.05),
        min(1.0, max(0.7, valid["Silhouette"].max() + 0.10)),
    )

    ax.grid(alpha=0.25)
    ax.legend()

    fig.tight_layout()

    sil_path = output_dir / f"silhouette_vs_k_{snapshot_key}.png"

    fig.savefig(sil_path, dpi=170, bbox_inches="tight")

    plt.close(fig)

    # ---------- Plot 3: Detailed Silhouette ----------

    if labels_for_detail is None:
        raise RuntimeError("Missing labels for detailed silhouette plot.")

    if np.unique(labels_for_detail).size < 2:
        raise RuntimeError("Fewer than two clusters in silhouette sample.")

    silhouettes = silhouette_samples(X_sample, labels_for_detail)

    sil_mean = float(np.mean(silhouettes))

    fig, ax = plt.subplots(figsize=(10, 6))

    y_bottom = 10

    palette = plt.rcParams["axes.prop_cycle"].by_key()["color"]

    for i, cluster_id in enumerate(sorted(np.unique(labels_for_detail))):

        cluster_vals = np.sort(silhouettes[labels_for_detail == cluster_id])

        cluster_count = len(cluster_vals)

        y_top = y_bottom + cluster_count

        ax.fill_betweenx(
            np.arange(y_bottom, y_top),
            0,
            cluster_vals,
            color=palette[i % len(palette)],
            alpha=0.8,
        )

        ax.text(
            -0.04,
            y_bottom + cluster_count / 2,
            f"{cluster_id} (n={cluster_count})",
            ha="right",
            va="center",
        )

        y_bottom = y_top + 14

    ax.axvline(
        sil_mean, linestyle="--", linewidth=1.8, label=f"Average: {sil_mean:.3f}"
    )

    ax.set_title(f"Silhouette Plot — K={detail_k}, " f"RFM snapshot {snapshot_key}")

    ax.set_xlabel("Silhouette value " "(higher = more distinct cluster)")

    ax.set_ylabel("Cluster ID (temporary labels; not segment names)")

    ax.set_xlim(-0.2, 1)
    ax.set_yticks([])

    ax.grid(axis="x", alpha=0.25)

    ax.legend()

    fig.tight_layout()

    detail_path = output_dir / f"silhouette_detail_k{detail_k}_{snapshot_key}.png"

    fig.savefig(detail_path, dpi=170, bbox_inches="tight")

    plt.close(fig)

    # ---------- Plot 4: PCA ----------

    # Load the actual saved model from SQL Server.
    # This allows us to use its stored segment names
    # instead of arbitrary temporary cluster IDs.

    cfg = fetch_config_by_version(model_version)

    mean, std, centroids = config_arrays(cfg)

    # Apply the scaler stored with the model.
    X_saved = build_scaler(mean, std).transform(to_log_matrix(clean))

    # Assign clusters using saved centroids.
    selected_rows = cfg.iloc[assign_clusters(X_saved, centroids)]

    saved_labels = selected_rows["ClusterID"].to_numpy(dtype=int)

    saved_names = dict(zip(cfg["ClusterID"].astype(int), cfg["ClusterSegment"]))

    pca_path = output_dir / f"pca_model_v{model_version}_{snapshot_key}.png"

    plot_clusters_pca(X_saved, saved_labels, saved_names, pca_path)

    # ---------- Plot 5: PCA for K=4 ----------

    k4_model = fit_kmeans(X_saved, 4)

    k4_labels = k4_model.labels_

    k4_names = {cid: f"Cluster {cid}" for cid in range(4)}

    pca_k4_path = output_dir / f"pca_k4_{snapshot_key}.png"

    plot_clusters_pca(X_saved, k4_labels, k4_names, pca_k4_path)

    print(f"Saved K=4 PCA: {pca_k4_path.resolve()}")

    # ---------- Output ----------

    print("\nSaved plots:")

    for path in (elbow_path, sil_path, detail_path, pca_path, csv_path):
        print(f"  {path.resolve()}")

    print("\nRead-only: no database tables " "or saved models were changed.")


# ---------- Command Line ----------


def main():

    parser = argparse.ArgumentParser(
        description=("Plot RFM K-Means elbow, silhouette, " "and PCA diagnostics.")
    )

    parser.add_argument(
        "--snapshot", type=int, default=20131231, help="Snapshot date key"
    )

    parser.add_argument(
        "--max-k", type=int, default=10, help="Maximum number of clusters to evaluate"
    )

    parser.add_argument(
        "--detail-k",
        type=int,
        default=BEST_K,
        help="K for the detailed silhouette plot",
    )

    parser.add_argument(
        "--model-version", default="1", help="Saved DimModelConfig version"
    )

    parser.add_argument(
        "--sample-size",
        type=int,
        default=2000,
        help="Number of customers used for silhouette",
    )

    parser.add_argument(
        "--output-dir", type=Path, default=Path("plots"), help="Output directory"
    )

    args = parser.parse_args()

    make_plots(
        args.snapshot,
        args.max_k,
        args.detail_k,
        args.sample_size,
        args.output_dir,
        args.model_version,
    )


if __name__ == "__main__":
    main()
