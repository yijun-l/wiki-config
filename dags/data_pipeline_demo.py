# Import required Airflow modules and datetime
from airflow import DAG
from airflow.operators.bash import BashOperator
from datetime import datetime

# Define a DAG for a simple data processing pipeline
with DAG(
    dag_id='data_processing_pipeline',          # Unique identifier for the DAG
    start_date=datetime(2024, 1, 1),            # Start date of the DAG
    schedule=None,                               # No automatic schedule, trigger manually
    catchup=False,                               # Disable backfilling for past dates
    tags=['data_pipeline', 'demo', 'bash']       # Tags for UI filtering
) as dag:

    # Task 1: Mark the start of the workflow
    start_task = BashOperator(
        task_id='start_workflow',
        bash_command='echo "=== Data pipeline started ===" && sleep 2',
    )

    # Task 2: Simulate data download from a source
    download_data_task = BashOperator(
        task_id='download_data',
        bash_command='echo "Downloading raw data..." && sleep 3 && echo "Data download completed"',
    )

    # Task 3: Simulate data cleaning and transformation
    process_data_task = BashOperator(
        task_id='process_data',
        bash_command='echo "Processing and cleaning data..." && sleep 3 && echo "Data processing completed"',
    )

    # Task 4: Simulate report generation
    generate_report_task = BashOperator(
        task_id='generate_report',
        bash_command='echo "Generating analytics report..." && sleep 2 && echo "Report generated successfully"',
    )

    # Task 5: Mark the end of the workflow
    end_task = BashOperator(
        task_id='end_workflow',
        bash_command='echo "=== Data pipeline finished successfully ===" && sleep 200',
    )

    # Define task dependencies (execution order)
    start_task >> download_data_task >> process_data_task >> generate_report_task >> end_task