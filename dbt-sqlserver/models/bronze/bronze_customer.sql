{{ config(materialized='table')}} -- overides the +materialized: view on dbt_project.yml



select * 
from {{ source('raw', 'customers')}}