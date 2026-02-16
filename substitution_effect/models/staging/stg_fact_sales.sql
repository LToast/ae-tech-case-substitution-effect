with source as (
    select * from {{ ref('fact_sales') }}
),

cleaned as (
    select
        transaction_id,
        cast(transaction_date as date) as transaction_date,
        store_code,
        transaction_channel_type,
        item_code,
        item_operation_type,
        quantity,
        cast(gmv as decimal(32,6)) as raw_gmv,
        
        -- Handle "Net GMV" logic at staging level to simplify downstream processing
        -- If it's a return, make the GMV negative
        case 
            when item_operation_type = 'return' then -1 * abs(gmv)
            else gmv 
        end as signed_gmv

    from source
    --where transaction_channel_type != 'Online' -- Exclude Online channel as per analysis scope
)

select * from cleaned