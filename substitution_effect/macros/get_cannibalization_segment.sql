{% macro get_cannibalization_segment(model_name_col, product_nature_col) %}
    case 
        -- 1. TARGET : Le produit 10kg
        when {{ model_name_col }} like '%10%' 
             and {{ product_nature_col }} = 'dumbbell kit' 
        then 'Target'

        -- 2. DIRECT : Le produit 20kg (Montée en gamme)
        when {{ model_name_col }} like '%20%' 
             and {{ product_nature_col }} = 'dumbbell kit' 
        then 'Direct Substitute'

        -- 3. INDIRECT : Les disques (Alternative fonctionnelle)
        when {{ product_nature_col }} = 'weight plate'
        then 'Indirect Substitute'

        -- 4. OTHER
        else 'Other'
    end
{% endmacro %}