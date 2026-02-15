# ae-tech-case-substitution-effect
Analytics technical case: Assessing the Economic Success of a Commercial Experiment

# 1. Understanding and Analytical Strategy

## Context and Problem Statement
The Domyos brand conducted an "A/B Test" (or quasi-experimental) experiment during weeks 35 to 41 of 2023. The action consisted of removing the **10 kg dumbbell kit** from the shelves of a selection of "Test" stores.

The objective of this analysis is to validate the following economic hypothesis: **Does the removal of the 10 kg kit cause sufficient sales transfer (cannibalization) to substitute products (e.g., 20 kg kit, individual weight plates) to offset the revenue loss?**

To answer this question, we cannot simply look at raw sales figures. It is necessary to isolate the test's impact by comparing **Test** vs **Control** stores (not tested), while neutralizing external biases (stock-outs, customer returns).

## Key KPI Definitions
To drive this decision, I structured the dashboard around the following indicators:

* **Net GMV (Gross Merchandise Value):** The actual revenue generated.
    * *Formula:* `SUM(GMV where type='purchase') - SUM(ABS(GMV) where type='return')`.
* **Cannibalization Rate:** The key indicator of the study.
    * *Definition:* It measures the portion of the "10kg" loss that was recovered by "Substitutes". If the rate is > 100%, the test is beneficial.
* **Stock Availability:** Percentage of days when products were actually available for sale (`top_available_stock = True`).
* **Transactions & Quantities:** Volume indicators to verify if purchase dynamics change (average basket, traffic).

## Key Considerations and Methodological Choices
During data exploration, I identified 4 critical points that guided my modeling:

### 1. The "Gross Margin" vs "GMV" Nuance
The instructions ask to analyze "Gross Margin Value". However, the provided data does not contain the cost of goods sold (COGS) for products.
* **Risk:** Applying an arbitrary margin rate (e.g., 40%) would distort the analysis, as a 20kg kit likely has a different margin than a 10kg kit.
* **Decision:** I will drive the analysis on **Net GMV**.
* *Note to business:* It is imperative to cross-reference these results with actual margin rates post-analysis to confirm final profitability.

### 2. Stock Management (Availability vs Sales)
The `fact_stock` table does not provide a quantity, but a boolean (`top_available_stock`). Comparing raw sales between two stores is biased if one experienced stock-outs independent of the test.
* **Decision:** Stock will be used as a validity filter. I will only compare sales performance on days when substitute products were **available** (Stock = True). This allows measuring actual demand rather than logistical capacity.

### 3. The "Online In-Store" Signal
Transactions marked as "Online" correspond to orders via sales tablet in-store.
* **Hypothesis:** An abnormal increase in "Online" sales of the 10kg kit in "Test" stores would signal failure (the customer refuses substitution and forces the order).
* **Decision:** I will distinguish "Offline" (shelf) revenue from "Online" revenue to measure this customer friction.

### 4. Data Quality (Returns)
The data contains operations of type `return` or `order_cancellation`.
* **Decision:** To avoid artificially inflating revenue, GMV calculation will be net of returns.

# 2. Data Engineering Design Doc: Cannibalization Analysis Project

## 1. Context & Business Logic
The goal of this project is to model the economic impact of removing a specific product (**10kg Dumbbell Kit**) from shelves to measure the sales transfer to substitute products.

### Data Strategy: The "Lab" Dataset
To validate our substitution logic, we constructed a specific dataset in `dim_model`. The challenge was to distinguish between **Direct Substitution** (upselling), **Indirect Substitution** (functional replacement), and **Noise**.

**Mock Data Breakdown:**

| Item Code | Model | Product Name | Weight | Category | **Assigned Segment** | **Logic** |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `1010` | 700 | **KIT HALTERE 10KG** | 10.0 | dumbbell kit | 🔴 **TARGET** | The specific product removed from shelves. |
| `2020` | 800 | **KIT HALTERE 20KG** | 20.0 | dumbbell kit | 🟢 **DIRECT SUB** | Upsell scenario (Higher price/margin). |
| `970069` | 1042303 | IRON DISC | 20.1 | weight plate | 🟡 **INDIRECT SUB** | Functional replacement (DIY Kit). |
| `2232193` | 8388695 | DISC RUBBER 2.5kg | 2.5 | weight plate | 🟡 **INDIRECT SUB** | Functional replacement (DIY Kit). |
| `125` | 7893 | DUMBBELL SINGLE 5kg | 5.4 | dumbbell | ⚪ **NOISE** | Same family, but not a valid substitute (Single vs Kit). |
| `3030` | 900 | TAPIS YOGA | 0.5 | yoga mat | ⚪ **NOISE** | Control group (completely unrelated). |

### Implementation: The Macro Approach
Instead of hardcoding SQL logic, we implemented a reusable macro `get_cannibalization_segment`. 
* **Why?** To centrally manage the definition of a "Substitute".
* **Result:** The macro correctly classifies `DUMBBELL SINGLE 5kgs` as **Other/Noise** because it matches neither the Kit logic nor the Plate logic, preventing false positives in the analysis.

---

## 2. dbt Architecture (Medallion)

We followed a standard Layered Architecture optimized for Databricks (Delta Lake).

### Staging (Silver)
* **Materialization:** `View` (Lightweight).
* **Key Transformation:** **Signed GMV**.
    * *Logic:* `CASE WHEN type = 'return' THEN -1 * abs(gmv) ELSE gmv END`.
    * *Benefit:* Allows downstream models to use simple `SUM(gmv)` without worrying about transaction types.
* **Channel Filtering:** We filter `transaction_channel_type = 'Offline'` to focus on shelf purchases, excluding online/tablet orders that bypass the physical removal constraint.

### Intermediate (Gold Preparation)
* **Materialization:** `Table` (Persisted for performance).
* **The "Fan Trap" Solution:** `int_sales_daily_stock`.
    * We pre-aggregate sales to the `Day/Store/Item` level *before* joining stock.
    * **Join Strategy:** `FULL OUTER JOIN` is used to preserve days with stock but no sales (for availability calculation) and days with sales but missing stock info (for data quality audit).

### Marts (Gold)
* **Materialization:** `Table`.
* **Key Feature:** **Availability Filter**.
    * Column: `is_stock_valid_for_analysis`.
    * *Usage:* BI tools must filter on `True` to compare sales only when substitutes were physically available on shelves.

---

## 3. Optimization Strategy
### A Incremental Models
* **Use Case:** `int_sales_daily_stock` is a heavy model that aggregates transaction-level data.
* **Incremental Strategy:** We *could* configure it as an **Incremental Model** with `unique_key=['store_code', 'item_code', 'transaction_date']` and an incremental strategy (e.g., `merge` or `insert_overwrite`).
* **Note:** Since this analysis focuses on a **fixed historical window** (weeks 35-41 of 2023), incremental processing provides limited value in this specific case. However, if this pipeline were extended to monitor ongoing experiments or continuous sales data, the incremental approach would significantly reduce compute costs by only processing new or modified transactions.

### B Databricks Specific Optimizations

We leveraged **Liquid Clustering** over traditional Partitioning/Z-Ordering for flexibility and skew handling.

| Layer | Model | Clustering Keys | Rationale |
| :--- | :--- | :--- | :--- |
| **Intermediate** | `int_sales_daily_stock` | `['store_code', 'item_code']` | **Join Optimization:** These are the keys used for the heavy Full Outer Join. Co-locating data minimizes network shuffle. |
| **Mart** | `mrt_kpi_dashboard` | `['store_code', 'item_code']` | **Filter Optimization:** Optimized for BI dashboards filtering by Store or Product. (Physical partitioning is handled by `date_day`). |

---

## 4. CI/CD & Workflow

We implement a robust CI/CD pipeline (e.g., GitHub Actions / GitLab CI) to ensure code quality before production.

### The Flow
1.  **Feature Branch:** Developers work on `feat/new-kpi`.
2.  **Pull Request (PR):** When opening a PR to `main`:
    * **Linting:** SQLFluff checks coding standards.
    * **Slim CI:** We run `dbt run --select state:modified+`. This only builds the models that changed and their downstream dependencies, saving compute time.
3.  **Regression Testing:** `dbt test` must pass on the modified models.
4.  **Merge to Prod:** Upon merge, the full pipeline runs in the `prod` schema.

### Environment Management
* **Dev:** Schema `dbt_username`. Data is a subset or full clone of prod.
* **Prod:** Schema `prod_analytics`. Read-only for users, writable only by the CI/CD service account.

---

## 5. Testing & Quality Assurance

### "Defense in Depth" Strategy
1.  **Generic Tests:** Uniqueness and Not Null constraints on all Primary Keys in `schema.yml`.

3.  **Relationship Tests:**
    * Foreign key integrity checks to ensure referential consistency between staging and intermediate layers.
4.  **Custom Data Tests:**
    * **Expression validation:** `dbt_utils.expression_is_true` to verify business rules (e.g., "daily_net_gmv IS NOT NULL OR is_available IS NOT NULL" on `int_sales_daily_stock`).
    * **Conditional not null:** Testing `daily_net_gmv` is not null when `is_available IS NULL`, ensuring data completeness for revenue calculations.
    * **Range validation:** `dbt_utils.accepted_range` to ensure numeric fields like `stock_days_available`, and `stock_days_expected` have logical values (e.g., >= 0).
    * **Accepted values with conditions:** Testing categorical fields like `transaction_channel_type` against whitelisted values only when the field is populated, preventing false failures on legitimate nulls.
    * **Unique combination tests:** `dbt_utils.unique_combination_of_columns` to validate composite primary keys (e.g., `store_code + date_day + cannibalization_segment` on `mrt_kpi_dashboard`).
2.  **Singular Tests (Business Logic):** * `assert_cannibalization_target_is_unique.sql`: Ensures our `LIKE '%10KG%'` logic is precise enough to capture exactly **one** item code as the Target. If it captures 0 or >1, the pipeline fails.

### Next Steps: Advanced Data Quality
To further harden the pipeline, we are considering two enhancements:

#### A. Great Expectations (GE) integration
While `dbt test` is great for constraints, GE is better for **Distributional Expectations**.
* *Use Case:* Detecting anomalies in GMV that aren't strict errors but are suspicious.
* *Concrete Example:*
    ```python
    # Expect the daily total GMV to be within 20% of the 30-day rolling average
    validator.expect_column_values_to_be_between(
        column="daily_net_gmv",
        min_value=0,
        max_value=10000 # Threshold based on historical max
    )
    ```

#### B. dbt Snapshots (SCD Type 2)
Currently, `dim_model` is a Type 1 dimension (overwritten).
* *Problem:* If the `product_weight` of an item is corrected in the source system from 10kg to 10.5kg, we lose history.
* *Solution:* Implement `snapshots/snp_dim_model.sql`.
    * **Strategy:** `check` strategy.
    * **Config:** `target_schema='snapshots'`, `unique_key='item_code'`, `check_cols=['product_weight', 'range_item']`.
    * **Benefit:** Allows us to replay history accurately even if product attributes change over time.