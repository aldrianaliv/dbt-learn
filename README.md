# dbt + SQL Server Guide

A step-by-step guide to setting up **dbt-core** with **SQL Server**, using a bronze → silver → gold (medallion) layout.

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Set Up a Python venv](#2-set-up-a-python-venv)
3. [Install dbt](#3-install-dbt)
4. [Create a dbt Project](#4-create-a-dbt-project)
5. [Set Up `.env` and `.gitignore`](#5-set-up-env-and-gitignore)
6. [Load `.env` When Running dbt](#6-load-env-when-running-dbt)
7. [Set Up `profiles.yml`](#7-set-up-profilesyml)
8. [Set Up `dbt_project.yml`](#8-set-up-dbt_projectyml)
9. [Bronze, Silver, Gold Layers](#9-bronze-silver-gold-layers)
10. [`source()` vs `ref()`](#10-source-vs-ref)
11. [Table Names and Aliases](#11-table-names-and-aliases)
12. [Running dbt](#12-running-dbt)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Prerequisites

| Tool | Windows | Debian/Ubuntu |
|---|---|---|
| Python 3.10–3.12 | `winget install Python.Python.3.12` | `sudo apt install python3 python3-venv python3-dev` |
| Git | `winget install Git.Git` | `sudo apt install git` |
| ODBC Driver 18 for SQL Server | `winget install Microsoft.msodbcsql.18` | see below |

**Linux: install the ODBC driver**

```bash
sudo apt install -y curl gnupg unixodbc unixodbc-dev build-essential
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
curl -fsSL https://packages.microsoft.com/config/debian/12/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list
sudo apt update
sudo ACCEPT_EULA=Y apt install -y msodbcsql18
```

**Check the driver is installed**

```powershell
Get-OdbcDriver | Where-Object Name -like "*SQL Server*"   # Windows
odbcinst -q -d                                            # Linux
```

You should see `ODBC Driver 18 for SQL Server`.

---

## 2. Set Up a Python venv

```powershell
mkdir C:\Projects\dbt
cd C:\Projects\dbt
python -m venv .venv
```

Activate it:

| Shell | Command |
|---|---|
| PowerShell | `.\.venv\Scripts\Activate.ps1` |
| cmd | `.venv\Scripts\activate` |
| Linux / Git Bash | `source .venv/bin/activate` |

> If PowerShell says `Activate.ps1 cannot be loaded`, run this once:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

You'll see `(.venv)` at the start of your prompt when it's active. **Always activate the venv before running dbt.**

---

## 3. Install dbt

```powershell
python -m pip install --upgrade pip
pip install dbt-sqlserver "python-dotenv[cli]"
dbt --version
```

- `dbt-sqlserver` also installs `dbt-core` and `pyodbc`, so you don't need to install those separately.
- `python-dotenv[cli]` is used to load `.env` (see [step 6](#6-load-env-when-running-dbt)).
- Using Snowflake instead? `pip install dbt-snowflake`.

---

## 4. Create a dbt Project

```powershell
dbt init my_project --skip-profile-setup
cd my_project
```

`--skip-profile-setup` skips the interactive prompts, since you'll write `profiles.yml` yourself.

Resulting structure:

```
my_project/
├── dbt_project.yml     # project settings
├── models/             # your .sql models and .yml configs
├── seeds/              # CSV files loaded with `dbt seed`
├── tests/              # custom SQL tests
├── macros/             # reusable Jinja/SQL functions
├── snapshots/          # slowly changing dimension tracking
└── analyses/           # ad-hoc SQL (compiled, never run)
```

Delete the example models:

```powershell
Remove-Item -Recurse -Force models\example     # Windows
rm -rf models/example                          # Linux
```

---

## 5. Set Up `.env` and `.gitignore`

Copy the examples into your project folder and fill in your values:

```powershell
copy ..\.env.example .env
copy ..\.gitignore.example .gitignore
```

**`.env`** (never commit this file)

```
SQLSERVER_HOST=localhost
SQLSERVER_PORT=1433
SQLSERVER_DATABASE=your_database
SQLSERVER_SCHEMA=dbt_dev
SQLSERVER_USER=your_user
SQLSERVER_PASSWORD=your_password

# Only needed if you use the prod target
SQLSERVER_PROD_HOST=prod-server.company.com
SQLSERVER_PROD_PORT=1433
SQLSERVER_PROD_DATABASE=prod_db
SQLSERVER_PROD_SCHEMA=analytics
SQLSERVER_PROD_USER=prod_user
SQLSERVER_PROD_PASSWORD=prod_password
```

**`.gitignore`**

```
.env
.venv/
target/
dbt_packages/
logs/
```

---

## 6. Load `.env` When Running dbt

### How it works

dbt **never opens `.env` by itself**. In `profiles.yml`, `{{ env_var('SQLSERVER_HOST') }}` reads the variable from the **environment of the dbt process**. Something has to load `.env` into that environment first:

```
.env  →  (loader)  →  environment variables  →  dbt run  →  env_var() reads them
```

If nothing loads it, dbt fails with `Env var required but not provided`.

### Option A: `dotenv run` (recommended)

Put `dotenv run --` in front of every dbt command:

```powershell
dotenv run -- dbt debug
dotenv run -- dbt run
dotenv run -- dbt build
```

It works the same on Windows and Linux. Run it from the folder that contains `.env`.

### Option B: Load once per terminal session

**PowerShell**: create `load-env.ps1`:

```powershell
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]*)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), 'Process')
    }
}
Write-Host "Loaded .env"
```

Then run it with a leading dot, so the variables stay in your session:

```powershell
. .\load-env.ps1
dbt run
```

**Linux / Git Bash**

```bash
set -a; source .env; set +a
dbt run
```

### Option C: Python wrapper

`run_dbt.py`:

```python
import subprocess
import sys
from dotenv import load_dotenv

load_dotenv()
sys.exit(subprocess.call(["dbt", *sys.argv[1:]]))
```

```powershell
python run_dbt.py run
python run_dbt.py build --select silver
```

---

## 7. Set Up `profiles.yml`

`profiles.yml` holds the **database connection**. Put it in the project root, next to `dbt_project.yml`.

### Where dbt looks for it (first match wins)

1. `--profiles-dir <folder>` flag
2. `DBT_PROFILES_DIR` environment variable
3. **The current folder** (recommended)
4. `~/.dbt/` (`C:\Users\<you>\.dbt\` on Windows)

Run `dbt debug --config-dir` to see which one dbt is using.

### Example

```yaml
my_project:                  # must match `profile:` in dbt_project.yml
  target: dev                # default target
  outputs:

    dev:
      type: sqlserver
      driver: "ODBC Driver 18 for SQL Server"
      server: "{{ env_var('SQLSERVER_HOST') }}"
      port: "{{ env_var('SQLSERVER_PORT', '1433') | as_number }}"
      database: "{{ env_var('SQLSERVER_DATABASE') }}"
      schema: "{{ env_var('SQLSERVER_SCHEMA', 'dbt_dev') }}"
      authentication: sql
      user: "{{ env_var('SQLSERVER_USER') }}"
      password: "{{ env_var('SQLSERVER_PASSWORD') }}"
      encrypt: true
      trust_cert: true       # accept self-signed certs (local/dev)
      threads: 4

    prod:
      type: sqlserver
      driver: "ODBC Driver 18 for SQL Server"
      server: "{{ env_var('SQLSERVER_PROD_HOST') }}"
      port: "{{ env_var('SQLSERVER_PROD_PORT', '1433') | as_number }}"
      database: "{{ env_var('SQLSERVER_PROD_DATABASE') }}"
      schema: "{{ env_var('SQLSERVER_PROD_SCHEMA') }}"
      authentication: sql
      user: "{{ env_var('SQLSERVER_PROD_USER') }}"
      password: "{{ env_var('SQLSERVER_PROD_PASSWORD') }}"
      encrypt: true
      trust_cert: false      # use a real certificate in prod
      threads: 8
```

### Field reference

| Field | Example | Notes |
|---|---|---|
| `server` | `localhost`, `192.168.1.10`, `x.database.windows.net` | No port here |
| `port` | `1433` | Needs `\| as_number` when it comes from `env_var` |
| `database` | `SalesDB` | Must already exist |
| `schema` | `dbt_dev` | dbt creates it if missing |
| `driver` | `ODBC Driver 18 for SQL Server` | Must match the installed driver name exactly |
| `env_var('X', 'default')` | | The second argument is the fallback if `X` isn't set |

### Other ways to log in

Replace the `authentication`, `user` and `password` lines with one of these:

```yaml
      windows_login: true                     # Windows account
```

```yaml
      authentication: ActiveDirectoryPassword # Azure AD user + password
      user: "{{ env_var('SQLSERVER_USER') }}"
      password: "{{ env_var('SQLSERVER_PASSWORD') }}"
```

```yaml
      authentication: CLI                     # uses your `az login` session
```

### Test the connection

```powershell
dotenv run -- dbt debug
```

Look for `All checks passed!`.

### Switching targets

```powershell
dotenv run -- dbt run                  # uses dev (the default)
dotenv run -- dbt run --target prod    # uses prod
```

---

## 8. Set Up `dbt_project.yml`

The main settings file: project name, which profile to use, folder locations, and how each model is built.

### How it links to `profiles.yml`

```yaml
# dbt_project.yml
name: 'my_project'
profile: 'my_project'   # ──┐
                        #   │ must match
# profiles.yml          #   │
my_project:             # ◄─┘
  target: dev
```

### Example

```yaml
name: 'my_project'               # lowercase, numbers, underscores only
version: '1.0.0'
config-version: 2
profile: 'my_project'

model-paths: ["models"]
seed-paths: ["seeds"]
test-paths: ["tests"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]
analysis-paths: ["analyses"]

target-path: "target"
clean-targets:                   # deleted by `dbt clean`
  - "target"
  - "dbt_packages"

models:
  my_project:                    # must match `name:` above
    +materialized: view          # default for all models

    silver:                      # = models/silver/
      +schema: silver
      +materialized: table
      +tags: ['silver']

    gold:                        # = models/gold/
      +schema: gold
      +materialized: table
      +tags: ['gold']

seeds:
  my_project:
    +schema: seeds

data_tests:
  +severity: error               # "warn" = report failures without failing the run
```

### Rules

- Keys under `models: my_project:` **mirror your folder names** (case-sensitive).
- A `+` prefix means "this is a config". Without it, dbt treats the key as a folder name.
- Settings are inherited by subfolders.
- `{{ config(...) }}` at the top of a `.sql` file overrides `dbt_project.yml`.

### Materializations

| Value | Creates | Use for |
|---|---|---|
| `view` | `CREATE VIEW` | Light transforms, always up to date |
| `table` | `CREATE TABLE` (rebuilt every run) | Models that BI tools query |
| `incremental` | Table that only inserts/updates new rows | Large fact tables |
| `ephemeral` | Nothing; inlined as a CTE | Small helper logic |

> **Ephemeral models** don't exist in the database. You can't query them in SSMS, `+schema` has no effect on them, and you can't run tests on them.

### SQL Server: columnstore

dbt-sqlserver builds tables with a clustered columnstore index by default. If your server doesn't support it:

```yaml
models:
  my_project:
    +as_columnstore: false
```

### Schema naming macro

By default dbt **combines** schema names: `schema: dbt_dev` in `profiles.yml` + `+schema: silver` gives `dbt_dev_silver`.

To get exactly `silver` and `gold`, create `macros/generate_schema_name.sql`:

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

dbt creates the schemas automatically on the first run.

---

## 9. Bronze, Silver, Gold Layers

### Concept

| Layer | Contains | Built by | Reads with |
|---|---|---|---|
| **Bronze** | Raw data, as loaded | Ingestion tool (SSIS, ADF, etc.) | |
| **Silver** | Cleaned, typed, deduplicated | dbt | `source('bronze', ...)` |
| **Gold** | Business-ready facts, dims, aggregates | dbt | `ref('silver_...')` |

Each layer only reads from the layer before it. dbt uses the `source()` and `ref()` calls to build a dependency graph (DAG), so it always runs bronze → silver → gold in the right order.

### Two ways to set up bronze

**Option 1: Use `dbo` as bronze (simplest)**

The raw tables in `dbo` *are* the bronze layer. dbt only reads them.

```
dbo.IBC_CUSTOMER  →  silver.silver_customers  →  gold.dim_customers
   (bronze)              (dbt)                       (dbt)
```

**Option 2: Copy `dbo` into a `bronze` schema**

dbt creates views in a `bronze` schema on top of `dbo`, then silver reads those views with `ref()`.

```
dbo.customers  →  bronze.bronze_customers  →  silver.silver_customers  →  gold...
  (raw)              (dbt view)                  (dbt)
```

Add this to `dbt_project.yml`:

```yaml
    bronze:
      +schema: bronze
      +materialized: view
```

The rest of this guide uses **Option 1**.

### Folder structure

```
models/
├── sources/
│   └── _bronze_sources.yml       # declares dbo as "bronze"
├── silver/
│   ├── _silver.yml               # tests
│   ├── silver_customers.sql
│   └── silver_orders.sql
└── gold/
    ├── _gold.yml
    ├── dim_customers.sql
    ├── fct_orders.sql
    └── agg_customer_sales.sql
```

```powershell
mkdir models\sources, models\silver, models\gold
```

### Sources: `models/sources/_bronze_sources.yml`

```yaml
version: 2

sources:
  - name: bronze                  # label used in source('bronze', ...)
    schema: dbo                   # actual schema in SQL Server
    tables:
      - name: customers           # name used in source('bronze', 'customers')
        identifier: IBC_CUSTOMER  # real table name (only needed if it's different)
      - name: orders
```

> **Declare each source only once.** If two `.yml` files both define a source with the same name, dbt fails with a duplicate-source error.

### Silver: `models/silver/silver_customers.sql`

```sql
with source as (
    select * from {{ source('bronze', 'customers') }}
),

deduped as (
    select
        *,
        row_number() over (partition by id order by updated_at desc) as rn
    from source
)

select
    cast(id as int)                     as customer_id,
    trim(first_name)                    as first_name,
    trim(last_name)                     as last_name,
    lower(trim(email))                  as email,
    try_cast(created_at as date)        as created_date,
    try_cast(updated_at as datetime2)   as updated_at
from deduped
where rn = 1
```

### Silver: `models/silver/silver_orders.sql`

```sql
with source as (
    select * from {{ source('bronze', 'orders') }}
),

deduped as (
    select
        *,
        row_number() over (partition by id order by updated_at desc) as rn
    from source
)

select
    cast(id as int)                     as order_id,
    cast(customer_id as int)            as customer_id,
    try_cast(order_date as date)        as order_date,
    upper(trim(status))                 as order_status,
    try_cast(amount as decimal(18,2))   as amount
from deduped
where rn = 1
  and id is not null
```

### Silver tests: `models/silver/_silver.yml`

```yaml
version: 2

models:
  - name: silver_customers        # must match the .sql file name
    columns:
      - name: customer_id
        data_tests: [unique, not_null]
      - name: email
        data_tests: [not_null]

  - name: silver_orders
    columns:
      - name: order_id
        data_tests: [unique, not_null]
      - name: customer_id
        data_tests:
          - relationships:
              to: ref('silver_customers')
              field: customer_id
      - name: order_status
        data_tests:
          - accepted_values:
              values: ['PENDING', 'SHIPPED', 'COMPLETED', 'CANCELLED']
```

### Gold: `models/gold/dim_customers.sql`

```sql
select
    customer_id,
    first_name,
    last_name,
    concat(first_name, ' ', last_name)  as full_name,
    email,
    created_date
from {{ ref('silver_customers') }}
```

### Gold: `models/gold/fct_orders.sql`

```sql
select
    order_id,
    customer_id,
    order_date,
    year(order_date)    as order_year,
    month(order_date)   as order_month,
    order_status,
    amount
from {{ ref('silver_orders') }}
where order_status <> 'CANCELLED'
```

### Gold: `models/gold/agg_customer_sales.sql`

```sql
select
    c.customer_id,
    c.full_name,
    count(f.order_id)   as total_orders,
    sum(f.amount)       as total_sales,
    min(f.order_date)   as first_order_date,
    max(f.order_date)   as last_order_date
from {{ ref('dim_customers') }} c
left join {{ ref('fct_orders') }} f
    on c.customer_id = f.customer_id
group by c.customer_id, c.full_name
```

### Gold tests: `models/gold/_gold.yml`

```yaml
version: 2

models:
  - name: dim_customers
    description: "One row per customer"
    columns:
      - name: customer_id
        data_tests: [unique, not_null]

  - name: fct_orders
    description: "One row per non-cancelled order"
    columns:
      - name: order_id
        data_tests: [unique, not_null]
```

### Lineage

```
source: bronze.customers ─► silver_customers ─► dim_customers ──┐
                                   │                            ├─► agg_customer_sales
source: bronze.orders ───► silver_orders ────► fct_orders ──────┘
```

### Result in SQL Server

```
SalesDB
├── dbo                      (bronze, loaded outside dbt)
│   ├── IBC_CUSTOMER
│   └── orders
├── silver
│   ├── silver_customers     (TABLE)
│   └── silver_orders        (TABLE)
└── gold
    ├── dim_customers        (TABLE)
    ├── fct_orders           (TABLE)
    └── agg_customer_sales   (TABLE)
```

### Layer rules

- **Silver** reads only `source('bronze', ...)`. Rename, cast, trim, dedupe, handle nulls. Most tests go here.
- **Gold** reads only `ref('silver_...')` or other gold models. Joins, business rules, aggregations.
- **Never skip a layer.** Gold reading bronze directly bypasses the cleaning and the tests.

### Incremental models (large tables)

```sql
{{ config(materialized='incremental', unique_key='order_id') }}

select ...
from {{ source('bronze', 'orders') }}

{% if is_incremental() %}
  where updated_at > (select max(updated_at) from {{ this }})
{% endif %}
```

The `updated_at` column must be included in the model's output for the `max()` lookup to work.

---

## 10. `source()` vs `ref()`

| | `source()` | `ref()` |
|---|---|---|
| Points to | Tables dbt **doesn't** build (raw/bronze) | Models dbt **does** build |
| Defined by | A `sources:` entry in any `.yml` under `models/` | The **`.sql` file name** |
| YAML required? | Yes | No (YAML only adds tests and docs) |
| Example | `{{ source('bronze', 'customers') }}` | `{{ ref('silver_customers') }}` |
| Compiles to | `SalesDB.dbo.IBC_CUSTOMER` | `SalesDB.silver.silver_customers` |

### How dbt finds sources

dbt scans **every `.yml` file under `models/`** and picks up anything under a top-level `sources:` key. **The folder and file names don't matter**, so `models/sources/` is just a convention.

```powershell
dotenv run -- dbt ls --resource-type source     # list every source dbt found
```

### See the real SQL

```powershell
dotenv run -- dbt compile --select silver_customers
```

Open `target/compiled/my_project/models/silver/silver_customers.sql` to see the SQL with every `source()` and `ref()` replaced by full table names.

---

## 11. Table Names and Aliases

### Default: the file name is the table name

```
models/silver/silver_customers.sql  →  SalesDB.silver.silver_customers
models/gold/dim_customers.sql       →  SalesDB.gold.dim_customers
```

- The **schema** comes from `+schema` in `dbt_project.yml`.
- The **table name** comes from the file name.
- **File names must be unique across the whole project**, even in different folders.

### Setting a different table name with `alias`

**In the `.sql` file** (most common):

```sql
{{ config(alias='customers') }}

select ...
```

**In a `.yml` file:**

```yaml
models:
  - name: silver_customers
    config:
      alias: customers
```

**In `dbt_project.yml`:**

```yaml
models:
  my_project:
    silver:
      silver_customers:
        +alias: customers
```

All three create `SalesDB.silver.customers`.

> **`ref()` always uses the file name, not the alias:**
> `{{ ref('silver_customers') }}` ✅  `{{ ref('customers') }}` ❌

### Strip the layer prefix automatically

`macros/generate_alias_name.sql`:

```sql
{% macro generate_alias_name(custom_alias_name=none, node=none) -%}
    {%- if custom_alias_name -%}
        {{ custom_alias_name | trim }}
    {%- elif node.name.startswith('silver_') -%}
        {{ node.name[7:] }}
    {%- elif node.name.startswith('gold_') -%}
        {{ node.name[5:] }}
    {%- else -%}
        {{ node.name }}
    {%- endif -%}
{%- endmacro %}
```

| File | Table |
|---|---|
| `silver_customers.sql` | `silver.customers` |
| `gold_customers.sql` | `gold.customers` |
| `dim_customers.sql` | `gold.dim_customers` |

> **Renaming a model or adding an alias doesn't drop the old table.** Drop it yourself:
> `DROP TABLE silver.silver_customers;`

---

## 12. Running dbt

```powershell
dotenv run -- dbt debug                          # test connection
dotenv run -- dbt ls                             # list all models
dotenv run -- dbt compile                        # render SQL into target/ without running it

dotenv run -- dbt run                            # build models
dotenv run -- dbt test                           # run tests
dotenv run -- dbt build                          # run + test in DAG order (recommended)

dotenv run -- dbt run --select silver            # one folder
dotenv run -- dbt run --select tag:gold          # by tag
dotenv run -- dbt run --select silver_orders     # one model
dotenv run -- dbt run --select +fct_orders       # model + everything upstream
dotenv run -- dbt run --select silver_orders+    # model + everything downstream

dotenv run -- dbt run --target prod              # use the prod target

dotenv run -- dbt docs generate
dotenv run -- dbt docs serve                     # docs + lineage graph in the browser

dbt clean                                        # delete target/ and dbt_packages/
```

> With `dbt build`, if a silver test fails, the gold models that depend on it are **skipped**, so bad data doesn't reach gold.

### Daily routine

```powershell
cd C:\Projects\dbt
.\.venv\Scripts\Activate.ps1
cd my_project
dotenv run -- dbt build
```

---

## 13. Troubleshooting

| Error | Fix |
|---|---|
| `Env var required but not provided` | `.env` wasn't loaded. Use `dotenv run -- dbt ...` from the folder containing `.env`. |
| `Could not find profile named 'my_project'` | `profile:` in `dbt_project.yml` doesn't match the top-level key in `profiles.yml`, or you're in the wrong folder. |
| `Can't open lib 'ODBC Driver 18...'` / `Data source name not found` | The driver isn't installed, or its name doesn't match `driver:` exactly. |
| `SSL Provider: certificate verify failed` | Set `trust_cert: true` (dev only). |
| `Login timeout expired` | Enable TCP/IP in SQL Server Configuration Manager, set port 1433, and restart the service. |
| `Login failed for user` | In SSMS: Server → Properties → Security → **SQL Server and Windows Authentication mode**, then restart the service. |
| `'1433' is not of type 'integer'` | Add `\| as_number` to `port`. |
| `depends on a source named ... which was not found` | The source isn't declared in any `.yml` under `models/`, or the name/table is misspelled. |
| `depends on a node named ... which was not found` | No `.sql` file with that name exists. `ref()` uses the file name, not the alias. |
| `found two sources with the name ...` | The same source is declared in two `.yml` files. Keep one. |
| `Configuration paths exist ... that do not apply` | A key in `dbt_project.yml` doesn't match a folder, or is missing its `+`. |
| Schema is `dbt_dev_silver` instead of `silver` | Add the `generate_schema_name` macro ([step 8](#schema-naming-macro)). |
| Columnstore error | Add `+as_columnstore: false` to `dbt_project.yml`. |
| `Activate.ps1 cannot be loaded` | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| YAML parsing errors | Use spaces, not tabs. Wrap Jinja in quotes: `"{{ env_var('X') }}"`. |
