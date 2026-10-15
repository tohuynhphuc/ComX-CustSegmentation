import mysql.connector 
import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler
# from sklearn.preprocessing import MinMaxScaler

MYSQL_CONFIG = {
    'host': 'localhost',
    'port': 3306,
    'user': 'root',
    'password': 'root',
    'database': 'CompanyX_DW',
    'auth_plugin': 'mysql_native_password',
}

def extract_dw_features():
    print('Connecting to Data Warehouse and extracting features....')
    conn = mysql.connector.connect(**MYSQL_CONFIG)

    query = """
    SELECT 
        p.ProfileKey,
        c.CustomerKey,
        p.Recency,
        p.Frequency,
        p.Monetary,
        TIMESTAMPDIFF(YEAR, c.BirthDate, '2025-12-31') AS Age,
        c.CountryName,
        c.RegionGroup,
        c.Education,
        c.Occupation,
        s.Gender,
        s.MaritalStatus,
        s.TotalChildren,
        s.NumberCarsOwned
    FROM DimCustomerProfile p
    INNER JOIN FactSales f ON p.ProfileKey = f.ProfileKey
    INNER JOIN DimCustomer c ON f.CustomerKey = c.SurrogateKey
    INNER JOIN SubDimCustomer s ON c.CustomerKey = s.CustomerKey
    WHERE c.isActivate = 1
    GROUP BY p.ProfileKey, c.CustomerKey, p.Recency, p.Frequency, p.Monetary, 
             c.BirthDate, c.CountryName, c.RegionGroup, c.Education, c.Occupation,
             s.Gender, s.MaritalStatus, s.TotalChildren, s.NumberCarsOwned;
    """

    df = pd.read_sql(query, conn)
    print(f' Extracted {len(df)} customer records.')
    return df 

def deduplicate_na_handle(df):
    print(' Deduplicating and handling missing values...')

    df_clean = df.copy()
    df_clean = df.drop_duplicates(subset=['CustomerKey'])

    numeric_cols = [
        'Recency',
        'Frequency',
        'Monetary',
        'Age',
        'TotalChildren',
        'NumberCarsOwned',
    ]
    df_clean['Monetary'] = df_clean['Monetary'].abs()
    df_clean['Recency'] = df_clean['Recency'].clip(lower=0)
    df_clean['Frequency'] = df_clean['Frequency'].clip(lower=1)

    for col in numeric_cols:
        if col in df_clean.columns and df_clean[col].isnull().sum() > 0:
            clean_median = df_clean[col].median()
            df_clean[col] = df_clean[col].fillna(clean_median)
            print(f"   Imputed missing in '{col}' with clean median: {clean_median}")
    
    print(f'Data cleaned. {len(df_clean)} records ready for scaling.')
    return df_clean

# Purpose: Log transformation for skewed features -> use np.log1 
# Then normalized it
def scale_rfm_features(df):
  """Log-transforms and standardizes the 3 RFM features for K-Means."""
  print('⏳ Log-transforming and scaling RFM features...')

  rfm_cols = ['Recency', 'Frequency', 'Monetary']
  df_prep = df.copy()

  # 1. Log-transform all 3 RFM features
  for col in rfm_cols:
    df_prep[col] = np.log1p(df_prep[col])

  # 2. Standardize (Mean=0, Std=1)
  scaler = StandardScaler()
  scaled_array = scaler.fit_transform(df_prep[rfm_cols])

  # 3. Output clean scaled DataFrame
  df_scaled = pd.DataFrame(scaled_array, columns=rfm_cols, index=df.index)
  df_scaled['CustomerKey'] = df['CustomerKey']
  df_scaled['ProfileKey'] = df['ProfileKey']

  return df_scaled, scaler


if __name__ == '__main__':
    df_raw = extract_dw_features()
    df_clean = deduplicate_na_handle(df_raw)
    df_scaled, scaler = scale_rfm_features(df_clean)

    print('\n--- CLEANED DATA ---')
    print(df_clean.head(5))

    print('\n--- SAMPLE SCALED DATA (READY FOR K-MEANS) ---')
    print(df_scaled.head(5))