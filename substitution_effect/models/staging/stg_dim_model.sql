with source as (
    select * from {{ ref('dim_model') }}
)

select
    -- Casting types to ensure consistency and prevent downstream issues (e.g., joins, calculations)
    cast(item_code as integer) as item_code,
    cast(model_code as integer) as model_code,
    cast(model_name as string) as model_name,
    cast(product_weight as double) as product_weight,
    cast(product_nature as string) as product_nature,
    cast(range_item as integer) as range_item,
    cast(picture_url as string) as picture_url
from source