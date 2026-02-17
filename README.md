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
        * **Join Strategy:** `FULL OUTER JOIN` preserves days with stock but no sales (for availability calculation) and days with sales but missing stock info (for data quality audit).
* **Temporal Control Design:** Seed file `ref_test_periods` defines baseline (Weeks 28-34) and test period (Weeks 35-41).
    * **Column:** `test_period_type` in `mrt_kpi_dashboard`.
    * **Benefit:** Enables Before/After comparison to isolate test effect from seasonality.

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

# 3. Dashboard Design & UX

## Philosophy: "Decision-First"
The goal of this dashboard is to allow the Commercial Director to validate or reject the product removal hypothesis in less than 10 seconds. The interface is structured according to a pyramidal logic (Top-Down): from the overall financial verdict to the detailed analytical explanation.

## Indicator Architecture

### 1. The Verdict (Header & Financial Impact)
This is the critical zone located at the top of the dashboard. It immediately answers the question: *"Is it profitable?"*.
* **Cannibalization Rate (%):** The master KPI. It represents the revenue recovery ratio.
    * *Reading:* If > 100%, the sales transfer to substitutes (20kg, discs) exceeds the loss from the 10kg.
* **Net Impact Bridge (€):** A simple visual equation to explain the financial mechanics:
    * `[Substitute Gain] - [10kg Target Loss] = [Net Result]`

### 2. Commercial Dynamics (Business Context)
This section helps understand *how* the result is obtained, through the 3 requested metrics:
* **Net GMV:** Overall business volume (net of returns).
* **Quantities Sold:** Allows verification of whether the transfer occurs in equivalent volumes or if fewer units are being sold (risk of traffic loss).
* **Transactions Count:** Monitors department foot traffic. A decline here would indicate that removing the 10kg product drives customers away without substitute purchases.

### 3. The Proof (Temporal View)
* **Stacked Area Chart:** A temporal visualization (Weeks 35-41) comparing "Test" vs "Control" sales curves.
* **Objective:** Visualize the trend break at the test launch (Week 35) and confirm that the increase in substitutes is indeed correlated with the removal of the 10kg.

### 4. Quality Guardrails (Reliability)
To ensure intellectual honesty in the analysis, two contextual indicators are displayed in the footer:
* **Stock Availability Rate:** If substitute stock (20kg) is low (<90%), the test is invalidated because sales transfer is physically impossible.
* **Online In-Store Share:** Monitors the rate of orders via sales tablet. An abnormal increase would signal customer friction (the customer "forces" the purchase of the unavailable 10kg).

## Dashboard Mockup
### Direct Substitution Dash :
![direct Substitution Dash](dash-direct.png)
### Indirect Substitution Dash :
![Indirect Substitution Dash](dash-indirect.png)
## Analysis & Recommendation: The Verdict

The dashboard analysis reveals a critical duality in the results, illustrating the importance of properly defining the observation scope:

* **Local Success (Direct Cannibalization: 125%):** For the identified direct substitutes (20kg Kit, Discs), the bet pays off. For every €100 of revenue lost on the 10kg, we recovered €125 on these specific products. Customers accept the upselling.
* **Global Failure (Indirect Cannibalization: 59.5%):** However, at the full category level ("Weights"), the recovery rate collapses. Removing the entry-level product (10kg) appears to have reduced overall traffic or conversion on other ancillary products.
* **Recommended Decision:** **STOP.** Despite the success on the 20kg, the overall revenue loss on the category (-40.5% net on the impacted scope) makes removing the 10kg Kit economically dangerous at this stage.

### TODO
Ajouter les tooltips de définition sur les KPIs

# 4. Next Steps & Industrialisation

Cette analyse initiale permet de visualiser les tendances. Pour passer à l'industrialisation et à la validation scientifique rigoureuse, je recommande les étapes suivantes.

## 4.1. Statistical Validation (Rigorous A/B Testing)
The current dashboard is descriptive. To confirm that the observed variations are not due to chance, we must formalize the statistical test.

### Hypotheses
* **Test Type:** "Two-sample t-test" (comparison of means) or ideally a **Difference-in-Differences (DiD)** method to neutralize historical biases between Test and Control stores.
* **Null Hypothesis ($H_0$):** The removal of the 10kg product has **no positive impact** on the overall GMV of the category ($\mu_{test} - \mu_{control} \le 0$).
* **Alternative Hypothesis ($H_1$):** The removal generates sufficient sales transfer to maintain or increase GMV ($\mu_{test} - \mu_{control} > 0$).

### Sample Size
To statistically validate this test in the future, we must define the sample size (number of stores/days) required upfront.
In a fast-paced Retail context ("Fail Fast"), I recommend a **Confidence Level of 80%** ($\alpha = 0.20$) rather than the academic standard of 95%, in order to accelerate decision-making.

**Calculation Formula (Evan Miller / Cohen's d):**

$$n = \frac{2\sigma^2(z_{\alpha/2} + z_{\beta})^2}{\delta^2}$$

*Where:*
* $n$ = Required sample size per group.
* $\alpha = 0.20$ (Accepted risk of false positive).
* $1-\beta = 0.80$ (Statistical power: probability of detecting an effect if it exists).
* $\delta$ (Delta) = The minimum detectable effect (e.g., we want to detect at least +2% GMV).
* $\sigma$ (Sigma) = The historical standard deviation of sales (variance).

## 4.2. Optimisation Databricks & Data Quality
Au-delà du partitionnement et du Liquid Clustering (déjà intégrés au modèle), l'industrialisation de ce pipeline nécessitera :

1.  **Delta Live Tables (DLT) & Expectations :**
    * Mise en place de contraintes de qualité strictes (ex: `CONSTRAINT valid_gmv EXPECT gmv > 0`, `EXPECT stock_boolean IS NOT NULL`).
    * Cela garantit que le dashboard ne s'alimente jamais avec des données corrompues (Stop pipeline on failure).

2.  **Materialized Views (Vues Matérialisées) :**
    * Plutôt que de recalculer les agrégations complexes (Jointure Ventes + Stock + Calendrier) à chaque ouverture du dashboard, nous créerons une Materialized View dans Databricks SQL.
    * *Avantage :* Réponse instantanée (<1s) pour l'utilisateur final sur Tableau/PowerBI, même sur des milliards de lignes.

3.  **Serverless SQL Warehouses :**
    * Using Serverless compute to handle peak loads on Monday mornings (weekend sales analysis) without paying for idle clusters during the rest of the week.

    ## 4.3. Towards "AI-Driven Analytics" (LLM-Ready)
    To anticipate future needs for natural language querying (Text-to-SQL) by business teams, the data model must be exposed through a **Semantic Layer**.

    The goal is to transform technical documentation into business context for an LLM (such as Databricks Genie or an internal RAG agent).

    1.  **Leveraging dbt Metadata as Context:**
        * Column descriptions in dbt's `schema.yml` files no longer serve only humans, but become the **"System Prompt"** for AI.
        * *Action:* Enrich dbt metadata to make calculation rules explicit (e.g., "GMV is gross revenue MINUS returns, not raw sales"). This prevents analytical hallucinations where the AI would invent a margin definition.

    2.  **Semantic Layer & Metrics:**
        * Rather than letting the AI generate complex `JOIN`s on the fly (a source of errors), we will expose certified metrics (via dbt Semantic Layer or MetricFlow).
        * *Example:* Define `cannibalization_rate` as an official metric. The user can then ask *"Why is the cannibalization rate dropping in week 38?"* and the AI will query the pre-calculated metric rather than attempt a hazardous division on raw data.

    3.  **AI Governance (Databricks Genie):**
        * By coupling this metadata (Unity Catalog) with a tool like **Databricks Genie**, we will enable the Commercial Director to explore "Long Tail Questions" (ad-hoc questions not anticipated in the dashboard) autonomously, with the guarantee that the AI respects the semantics defined by the Data team.