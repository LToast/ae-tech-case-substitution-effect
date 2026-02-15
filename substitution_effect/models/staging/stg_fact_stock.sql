select 
    cast(stock_date as date) as stock_date,
    store_code,
    item_code,
    top_suivi,
    top_available_stock
from {{ ref('fact_stock') }}