

select *
from {{ ref('dim_customers') }} c       
left join {{ ref('fct_orders') }} f
    on c.id = f.id