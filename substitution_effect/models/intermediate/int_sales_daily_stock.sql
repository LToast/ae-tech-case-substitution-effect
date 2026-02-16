-- Intermediate model: Daily stock levels joined with sales data
-- 
-- Liquid Clustering Configuration:
-- - store_code: Primary dimension for store-level queries and aggregations. Most analysis 
--   and reporting will filter or group by store, making this a natural clustering key.
-- - item_code: Secondary dimension for product-level analysis. Combined with store_code, 
--   this enables efficient queries for store-item combinations, which are the most common 
--   access patterns in inventory and sales analysis.
--
-- These columns were chosen because:
-- 1. High cardinality: Both columns have many distinct values, providing good data distribution
-- 2. Common filter predicates: Queries typically filter by store and/or item
-- 3. Join optimization: These are likely foreign keys used in joins with dimension tables
-- 4. Query patterns: Most analytical queries access data at the store-item grain
{{ config(
    materialized='table',
    liquid_clustered_by=['store_code', 'item_code'] 
) }}

with daily_sales as (
    -- 1. Aggregate transaction-level granularity to match stock granularity
    select
        transaction_date,
        store_code,
        item_code,
        transaction_channel_type, -- Keep this for Online/Offline analysis
        sum(signed_gmv) as daily_net_gmv,
        sum(case when item_operation_type = 'sale' then quantity else 0 end) as quantity_sold,
        sum(case when item_operation_type = 'return' then quantity else 0 end) as quantity_returned,
        count(distinct transaction_id) as nb_transactions
    from {{ ref('stg_fact_sales') }}
    group by 1, 2, 3, 4
),

stock as (
    select * from {{ ref('stg_fact_stock') }}
),

joined as (
    -- 2. Full Outer Join because we want:
    -- - Days with sales (even if stock is missing, which would be a data error but needs to be visible)
    -- - Days without sales but with stock (to calculate availability)
    select
        coalesce(s.stock_date, d.transaction_date) as date_day,
        coalesce(s.store_code, d.store_code) as store_code,
        coalesce(s.item_code, d.item_code) as item_code,
        
        -- Dimensions
        d.transaction_channel_type, -- Note: NULL if no sales on that day
        
        -- Sales Metrics
        coalesce(d.daily_net_gmv, 0) as daily_net_gmv,
        coalesce(d.quantity_sold, 0) as quantity_sold,
        coalesce(d.quantity_returned, 0) as quantity_returned,
        coalesce(d.nb_transactions, 0) as nb_transactions,
        
        -- Stock Metrics
        coalesce(s.top_available_stock, false) as is_available,
        coalesce(s.top_suivi, false) as is_tracked

    from stock s
    full outer join daily_sales d 
        on s.stock_date = d.transaction_date
        and s.store_code = d.store_code
        and s.item_code = d.item_code
)

select * from joined