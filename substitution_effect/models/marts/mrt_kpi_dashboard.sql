{{ config(
    materialized='table',
    partition_by='date_day',
    tags=['bi_gold']
) }}

with facts as (
    select * from {{ ref('int_sales_daily_stock') }}
),

items as (
    select * from {{ ref('stg_dim_model') }}
),

stores as (
    select * from {{ ref('stg_dim_store') }}
)

select
    f.date_day,
    f.store_code,
    s.location,
    s.is_tested_region,
    f.item_code,
    i.model_name,
    i.product_nature,
    -- Cannibalization Logic (Preparation)
    -- Identify if it's the "10kg" product or the "Substitute"
    {{ get_cannibalization_segment('model_name', 'product_nature') }} as cannibalization_segment,

    -- Handle NULL channel when there's no sale (pure stock days)
    -- coalesce(f.transaction_channel_type, 'N/A') as channel_type,

    -- KPI 1: Net GMV
    f.daily_net_gmv,

    -- KPI 2: Stock Availability (Denominator & Numerator logic)
    -- Count 1 if product was tracked (expected), and check if it was available
    case when f.is_tracked then 1 else 0 end as stock_days_expected,
    case when f.is_tracked and f.is_available then 1 else 0 end as stock_days_available,

    -- KPI 3: Volume
    f.quantity_sold,
    f.nb_transactions,



    -- Validity filter for analysis

    f.is_available as is_stock_valid_for_analysis

from facts f
left join items i on f.item_code = i.item_code
left join stores s on f.store_code = s.store_code