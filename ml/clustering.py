import matplotlib.pyplot as plt
import pandas as pd
from preprocess_data import deduplicate_na_handle, extract_dw_features, scale_rfm_features
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score
from sklearn.decomposition import PCA

import mysql.connector 
MYSQL_CONFIG = {
    'host': 'localhost',
    'port': 3306,
    'user': 'root',
    'password': 'root',  # Update with your password
    'database': 'CompanyX_DW',
    'auth_plugin': 'mysql_native_password',
}

# Take data from dw
df_raw = extract_dw_features()
df_clean = deduplicate_na_handle(df_raw) # Means cleaned data, prepared for processing
df_scaled, scaler = scale_rfm_features(df_clean) # Normalized data using Standard Scaler

features = ['Recency', 'Frequency', 'Monetary']
inertia_scores = []
silhouette_scores = []
K_range = range(2, 8)

# First K-Means to find the optimal K
for k in K_range:
    kmeans = KMeans(
        n_clusters=k, 
        init='k-means++', 
        n_init=10, 
        random_state=42
    )
    kmeans.fit(df_scaled[features])
    inertia_scores.append(kmeans.inertia_)
    silhouette_scores.append(silhouette_score(df_scaled[features], kmeans.labels_))

# Chosen from plotting diagram (the plotting diagram is commented out below)
best_k = 4
kmeans = KMeans(
    n_clusters=best_k, 
    init='k-means++', 
    n_init=10, 
    max_iter=300, 
    random_state=42
)

# Predict Cluster IDs
df_clean['ClusterID'] = kmeans.fit_predict(df_scaled[features])

def auto_assign_rfm_segments(df):

    # 1. Calculate cluster means
    means = df.groupby('ClusterID')[['Recency', 'Frequency', 'Monetary']].mean()
    
    # 2. Award Points (1 to 4):
    m_points = means['Monetary'].rank(ascending=True)
    f_points = means['Frequency'].rank(ascending=True)
    r_points = means['Recency'].rank(ascending=False)
    
    # 3. Composite Value Score (1.1x weight on Recency as active vs. at-risk tie-breaker)
    means['CompositeScore'] = m_points + f_points + (r_points * 1.1)
    
    # 4. Sort clusters from Highest Value (1st) to Lowest Value (4th)
    sorted_clusters = means.sort_values(by='CompositeScore', ascending=False).index.tolist()
    
    # 5. Segment Personas in order of overall customer value
    segment_hierarchy = [
        'Champions',          # Rank 1: Highest overall value
        'Active',             # Rank 2: Good spend, bought recently
        'At-Risk',            # Rank 3: Good historical spend, slipping away
        'Lost / Dormant'      # Rank 4: Lowest spend, inactive longest
    ]
    
    cluster_mapping = dict(zip(sorted_clusters, segment_hierarchy))
    
    print("\nDynamic Composite Rank Assignments:")
    for cid, name in cluster_mapping.items():
        score = means.loc[cid, 'CompositeScore']
        print(f"   Cluster {cid} (Composite Score: {score:.1f}) -> {name}")
    df['CustomerSegment'] = df['ClusterID'].map(cluster_mapping)
    return df

# Apply dynamic naming
df_clean = auto_assign_rfm_segments(df_clean)

df_cluster_profile = df_clean.groupby(['ClusterID', 'CustomerSegment']).agg(
    Recency_mean=('Recency', 'mean'),
    Frequency_mean=('Frequency', 'mean'),
    Monetary_mean=('Monetary', 'mean'),
    Customer_counts=('CustomerKey', 'count')
).reset_index()

print('\n--- CLUSTER PROFILE SUMMARY ---')
print(df_cluster_profile.to_string(index=False))

print('\n--- SAMPLE LABELED CUSTOMERS ---')
print(df_clean[['CustomerKey', 'Recency', 'Frequency', 'Monetary', 'ClusterID', 'CustomerSegment']].head(10))






# 6. PLOTTING & VISUALIZATION
# # --- A. Elbow Method & Silhouette Score Curves ---
# fig, ax = plt.subplots(1, 2, figsize=(12, 4))
# ax[0].plot(K_range, inertia_scores, 'bo-')
# ax[0].set_xlabel('Number of Clusters (K)'); ax[0].set_ylabel('Inertia')
# ax[0].set_title('Elbow Method')
# ax[0].grid(True)
#
# ax[1].plot(K_range, silhouette_scores, 'go-')
# ax[1].set_xlabel('Number of Clusters (K)'); ax[1].set_ylabel('Silhouette Score')
# ax[1].set_title('Silhouette Score')
# ax[1].grid(True)
# plt.tight_layout()
# plt.show()
#
# # --- B. 2D PCA Cluster Scatter Plot ---
# pca = PCA(n_components=2)
# df_pca = pca.fit_transform(df_scaled[features])
#
# plt.figure(figsize=(8, 6))
# scatter = plt.scatter(
#     df_pca[:, 0], df_pca[:, 1], 
#     c=df_clean['ClusterID'], 
#     cmap='tab10', 
#     alpha=0.7, 
#     s=45
# )
# plt.xlabel('Principal Component 1')
# plt.ylabel('Principal Component 2')
# plt.title('Customer Clusters Visualized (PCA 2D)')
# legend = plt.legend(*scatter.legend_elements(), title='Cluster ID', loc='best')
# plt.grid(True)
# plt.show()
#
# # --- C. 3D Interactive RFM Scatter Plot ---
# fig = plt.figure(figsize=(9, 7))
# ax = fig.add_subplot(111, projection='3d')
# scatter = ax.scatter(
#     df_clean['Recency'],
#     df_clean['Frequency'],
#     df_clean['Monetary'],
#     c=df_clean['ClusterID'],
#     cmap='tab10',
#     s=50,
#     alpha=0.8
# )
# ax.set_xlabel('Recency (Days)', fontweight='bold')
# ax.set_ylabel('Frequency (Orders)', fontweight='bold')
# ax.set_zlabel('Monetary ($ Spend)', fontweight='bold')
# ax.set_title(f'3D Customer Clusters (K={best_k})', fontsize=14)
# legend = ax.legend(*scatter.legend_elements(), title='Cluster ID', loc='best')
# ax.add_artist(legend)
# plt.tight_layout()
# plt.show()
