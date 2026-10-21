# dags/ml_customer_segmentation_dag.py
import sys
from datetime import datetime, timedelta
from pathlib import Path

from airflow import DAG
from airflow.operators.python import PythonOperator

# Use the path as Airflow sees it. If Airflow runs in WSL, use the /mnt/d/... form.
ML_DIR = Path("/mnt/d/Trac/Uni/4th/BI/ml_section/ml")
sys.path.insert(0, str(ML_DIR))

from ml.train_model import train_version


def train_for_closing_year(**ctx):
    conf = ctx["dag_run"].conf or {}
    if "year" in conf:  # manual run, for example {"year": 2026}
        year = int(conf["year"])
    else:  # scheduled run at 00:10 on 1 January
        year = (ctx["data_interval_end"] - timedelta(days=1)).year
    train_version(year)


with DAG(
    dag_id="rfm_year_end_training",
    start_date=datetime(2026, 1, 1),
    schedule="0 10 1 1 *",  # 00:10 on 1 January every year
    catchup=False,
    default_args={"retries": 3, "retry_delay": timedelta(minutes=30)},
) as dag:
    PythonOperator(task_id="train_model", python_callable=train_for_closing_year)
