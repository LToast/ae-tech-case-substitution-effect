with periods as (
    select * from {{ ref('ref_test_periods') }}
)

select 
    period_name,
    start_date,
    end_date
from periods