with source as (
    select * from {{ ref('dim_store') }}
)

select
    cast(store_code as integer) as store_code,
    cast(sales_area as integer) as sales_area,
    cast(location as string) as location,
    cast(is_tested_region as boolean) as is_tested_region,
    cast(family_range as integer) as family_range
from source