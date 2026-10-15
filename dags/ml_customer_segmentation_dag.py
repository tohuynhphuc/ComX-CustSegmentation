from datetime import datetime, timedelta
import os
import sys
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.providers.common.sql.sensors.sql import SqlSensor

DAGS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(DAGS_DIR, '..'))
CLUSTERING_SCRIPT = os.path.join(PROJECT_ROOT, 'ml', 'clustering.py')
PYTHON_EXE = sys.executable

default_args = {
    'owner': 'ml_member_trac',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=2),
}

with DAG(
    dag_id='customer_ml_pipeline',
    default_args=default_args,
    description='Automated K-Means Clustering and Write-Back for CompanyX_DW',
    schedule_interval='*/15 * * * *',  # Runs every 15 minutes (near real-time)
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=['machine_learning', 'customer_segmentation', 'mysql_dw'],
) as dag:

  # 1. Check if Data Warehouse has sales data
  check_data_ready = SqlSensor(
      task_id='check_data_ready',
      conn_id='mysql_companyx_dw',
      sql='SELECT COUNT(*) FROM FactSales;',  # Fixed SQL syntax
      mode='poke',
      poke_interval=30,
      timeout=300,
  )

  # 2. Run ML script dynamically using resolved path
  run_ml_clustering = BashOperator(
      task_id='run_ml_clustering_and_writeback',
      bash_command=f'"{PYTHON_EXE}" "{CLUSTERING_SCRIPT}"',
  )
  
  check_data_ready >> run_ml_clustering 