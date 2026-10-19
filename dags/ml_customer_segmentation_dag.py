from datetime import datetime

from airflow import DAG
from airflow.operators.python import PythonOperator

from ml.train_model import train_version


def train_for_year(**ctx):
    train_version(ctx['logical_date'].year)


with DAG('rfm_year_end_training', start_date=datetime(2026, 1, 1),
         schedule='0 6 31 12 *', catchup=False) as dag:
    PythonOperator(task_id='train_model', python_callable=train_for_year)