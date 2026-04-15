from airflow import DAG
from airflow.operators.bash import BashOperator
from datetime import datetime

with DAG(
    dag_id='my_first_test_dag',
    start_date=datetime(2024, 1, 1),
    schedule=None,
    catchup=False
) as dag:
    task1 = BashOperator(
        task_id='say_hello',
        bash_command='echo "Hello Airflow 3.0!"'
    )