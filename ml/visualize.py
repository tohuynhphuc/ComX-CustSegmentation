import os

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler

from ml.model_core import extract_snapshot, clean_rfm, to_log_matrix
from train_model import BEST_K, build_segment_mapping

YEAR_END = 20141231            # snapshot the analysis is based on
K_RANGE = range(2, 9)
RANDOM_STATE = 42
SILHOUETTE_SAMPLE = 5000       # silhouette on a random sample; the full set is slow
OUT_DIR = 'figures'


def load_scaled_data():
    """Same cleaning and scaling as training, so the figures describe the model that was trained."""
    df = clean_rfm(extract_snapshot(YEAR_END))
    X = StandardScaler().fit_transform(to_log_matrix(df))
    return df, X


def evaluate_k(X):
    """Fit K-Means for each K and record WCSS (inertia) and average silhouette."""
    rows = []
    for k in K_RANGE:
        km = KMeans(n_clusters=k, init='k-means++', n_init=10, max_iter=300, random_state=RANDOM_STATE)
        labels = km.fit_predict(X)
        sil = silhouette_score(X, labels, sample_size=SILHOUETTE_SAMPLE, random_state=RANDOM_STATE)
        rows.append({'K': k, 'WCSS': km.inertia_, 'Silhouette': sil})
        print(f'K={k}  WCSS={km.inertia_:.1f}  silhouette={sil:.3f}')
    return pd.DataFrame(rows)


def plot_elbow_silhouette(results, path):
    """Two panels side by side: elbow (WCSS) on the left, silhouette on the right."""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.5))

    ax1.plot(results['K'], results['WCSS'], marker='o')
    ax1.axvline(BEST_K, linestyle='--', color='gray', label=f'Chosen K = {BEST_K}')
    ax1.set_xlabel('Number of clusters (K)')
    ax1.set_ylabel('WCSS (inertia)')
    ax1.set_title('Elbow method')
    ax1.legend()

    ax2.plot(results['K'], results['Silhouette'], marker='o', color='tab:green')
    ax2.axvline(BEST_K, linestyle='--', color='gray', label=f'Chosen K = {BEST_K}')
    ax2.set_xlabel('Number of clusters (K)')
    ax2.set_ylabel('Average silhouette score')
    ax2.set_title('Silhouette score')
    ax2.legend()

    fig.tight_layout()
    fig.savefig(path, dpi=300)
    plt.close(fig)


def plot_clusters_pca(X, labels, names, path):
    """Project the scaled RFM space to 2D with PCA and colour each customer by its cluster."""
    pca = PCA(n_components=2, random_state=RANDOM_STATE)
    coords = pca.fit_transform(X)
    var = pca.explained_variance_ratio_ * 100

    cmap = plt.get_cmap('viridis', BEST_K)
    fig, ax = plt.subplots(figsize=(7, 6))
    for cid in sorted(names):
        mask = labels == cid
        ax.scatter(coords[mask, 0], coords[mask, 1], s=18, alpha=0.6,
                   color=cmap(cid), label=f'{names[cid]} (cluster {cid})')

    ax.set_xlabel(f'Principal Component 1 ({var[0]:.1f}% variance)')
    ax.set_ylabel(f'Principal Component 2 ({var[1]:.1f}% variance)')
    ax.set_title(f'Customer clusters (PCA 2D), K = {BEST_K}')
    ax.legend(markerscale=2)
    fig.tight_layout()
    fig.savefig(path, dpi=300)
    plt.close(fig)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    df, X = load_scaled_data()

    results = evaluate_k(X)
    results.to_csv(os.path.join(OUT_DIR, 'k_selection.csv'), index=False)
    plot_elbow_silhouette(results, os.path.join(OUT_DIR, 'elbow_silhouette.png'))

    # Same parameters as train_model.py, so these labels match what the model produces.
    km = KMeans(n_clusters=BEST_K, init='k-means++', n_init=10, max_iter=300, random_state=RANDOM_STATE)
    labels = km.fit_predict(X)
    df['ClusterID'] = labels
    names = build_segment_mapping(df)
    plot_clusters_pca(X, labels, names, os.path.join(OUT_DIR, 'clusters_pca.png'))

    print(f'Figures and k_selection.csv saved to ./{OUT_DIR}/')


if __name__ == '__main__':
    main()