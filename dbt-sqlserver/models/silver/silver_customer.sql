{{ config(alias='customers')}}

with source as (
    select * 
    from {{ ref('bronze_customers')}}
),
deduped as (
    select *,
    row_number() over (partition by id order by updated_at desc) as rn
    from source -- {{ source('bronze', 'customer') }} if model/bronze/ is skipped 
)

select *
from deduped
where rn = 1



