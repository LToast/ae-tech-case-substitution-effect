-- This test verifies that the "Target" logic does not accidentally capture
-- other products than our specific 10kg Kit.

with calculated_segments as (
    select 
        item_code,
        model_name,
        product_nature,
        {{ get_cannibalization_segment('model_name', 'product_nature') }} as segment
    from {{ ref('stg_dim_model') }}
),

target_products as (
    select * from calculated_segments
    where segment = 'Target'
)

-- The test fails if we find more than one different model_code identified as "Target"
select 
    count(distinct item_code) as distinct_targets
from target_products
having count(distinct item_code) > 1