# ClickHouse DWH Cluster - Production Documentation

## Содержание
1. [Обзор проекта](#обзор-проекта)
2. [Архитектура кластера](#архитектура-кластера)
3. [Требования к инфраструктуре](#требования-к-инфраструктуре)
4. [Топология и конфигурация](#топология-и-конфигурация)
5. [Балансировка нагрузки](#балансировка-нагрузки)
6. [Управление пользователями (RBAC)](#управление-пользователями-rbac)
7. [Мониторинг и метрики](#мониторинг-и-метрики)
8. [Производительность и оптимизация](#производительность-и-оптимизация)
9. [Резервное копирование](#резервное-копирование)
10. [Troubleshooting](#troubleshooting)

---

## Обзор проекта

Отказоустойчивый кластер ClickHouse для построения корпоративного Data Warehouse с интеллектуальной балансировкой нагрузки и полным стеком мониторинга.

### Ключевые характеристики

**Топология**:
- 1 шард, 3 реплики (полная репликация данных)
- Специализация нод: Write-optimized (Node-01) + Read-optimized (Node-02/03)

**Отказоустойчивость**:
- ZooKeeper quorum (3 ноды) - работа при падении 1 ноды
- ClickHouse replicas (3 ноды) - работа при падении до 1 ноды
- Автоматическое восстановление данных через репликацию

**Технологический стек**:
- ClickHouse 24.3 (колоночная СУБД для аналитики)
- ZooKeeper 3.8 (координация и консенсус)
- HAProxy 2.8 (балансировщик нагрузки)
- Prometheus + Grafana (мониторинг)

---

## Архитектура кластера

### Диаграмма компонентов

```
                        ┌─────────────────┐
                        │   HAProxy LB    │
                        │  (VM-7)         │
                        │  8080-82, 9090-91│
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
    ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
    │ ClickHouse-01   │ │ ClickHouse-02   │ │ ClickHouse-03   │
    │ (VM-1)          │ │ (VM-2)          │ │ (VM-3)          │
    │ Write-heavy     │ │ Read-heavy      │ │ Read-heavy      │
    │ replica_01      │ │ replica_02      │ │ replica_03      │
    └────────┬────────┘ └────────┬────────┘ └────────┬────────┘
             │                   │                   │
             └───────────────────┼───────────────────┘
                                 │
                      ┌──────────┴──────────┐
                      │  ZooKeeper Ensemble  │
                      │  (VM-4, VM-5, VM-6)  │
                      │  Quorum: 2 of 3      │
                      └─────────────────────┘

                      ┌─────────────────────┐
                      │  Monitoring (VM-7)  │
                      │  Prometheus:9099    │
                      │  Grafana:3000       │
                      └─────────────────────┘
```

### Принцип работы

**Запись данных (INSERT)**:
1. Запрос приходит на HAProxy (порт 8080 ETL endpoint)
2. HAProxy направляет на ClickHouse-01 (write-optimized)
3. ClickHouse-01 записывает данные локально
4. ZooKeeper фиксирует операцию в replicated log
5. ClickHouse-02 и ClickHouse-03 копируют данные (или готовые части после merge)

**Чтение данных (SELECT)**:
1. **Аналитика**: HAProxy (8081) → равномерно на все 3 ноды (balance leastconn)
2. **Отчеты**: HAProxy (8082) → приоритет на Node-02/03 (balance source)
3. Все ноды имеют одинаковые данные → любая может ответить на запрос

---

## Требования к инфраструктуре

### Виртуальные машины (Production)

#### ClickHouse Nodes (VM-1, VM-2, VM-3)

**Характеристики каждой VM**:
```yaml
CPU: 16-32 cores (физических)
RAM: 64-128 GB
Disk: 2-4 TB NVMe SSD (RAID10 рекомендуется)
Network: 10 Gbps
OS: Ubuntu 22.04 LTS / RHEL 8+
```

**Расчет ресурсов под вашу нагрузку**:
- Текущие данные: ~5B записей = 2.4 TB (с репликацией ×3)
- Прирост: 1.5M-8M строк/день = ~840 GB/год (с репликацией)
- **Рекомендация**: 2 TB на ноду хватит на 2-3 года

**Обоснование ресурсов**:
- **CPU 16-32 cores**: ClickHouse параллелизует запросы по ядрам
- **RAM 64-128 GB**:
  - Node-01: 90% для буферов INSERT и background merges
  - Node-02/03: 85% для кэширования (mark cache 10GB + uncompressed cache 20GB)
- **Disk 2-4 TB NVMe**:
  - Высокая скорость записи для ETL
  - Низкая latency для аналитических запросов

#### ZooKeeper Nodes (VM-4, VM-5, VM-6)

**Характеристики каждой VM**:
```yaml
CPU: 4 cores
RAM: 8 GB
Disk: 100 GB SSD
Network: 1 Gbps
OS: Ubuntu 22.04 LTS / RHEL 8+
```

**Обоснование**:
- ZooKeeper хранит только метаданные (KB-MB размер)
- Требователен к latency диска (SSD обязательно)
- 3 ноды = quorum (работает при падении 1 ноды)

#### Infrastructure Node (VM-7)

**Характеристики**:
```yaml
CPU: 4-8 cores
RAM: 16 GB
Disk: 200 GB SSD
Network: 10 Gbps (для HAProxy)
OS: Ubuntu 22.04 LTS
```

**Сервисы**:
- HAProxy (балансировщик)
- Prometheus (метрики, retention 30 дней)
- Grafana (визуализация)

### Сетевые требования

**Внутренняя сеть**:
- Выделенная VLAN между всеми нодами
- Latency < 1ms (критично для ZooKeeper)
- Bandwidth: 10 Gbps для ClickHouse нод

**Firewall правила**:

| VM | Порты | Назначение |
|----|-------|------------|
| VM-1,2,3 | 8123 | ClickHouse HTTP API |
| VM-1,2,3 | 9000 | ClickHouse Native protocol |
| VM-1,2,3 | 9009 | ClickHouse Interserver (репликация) |
| VM-1,2,3 | 9363 | Prometheus metrics |
| VM-4,5,6 | 2181 | ZooKeeper client |
| VM-4,5,6 | 2888 | ZooKeeper peer |
| VM-4,5,6 | 3888 | ZooKeeper election |
| VM-7 | 8080-8082 | HAProxy HTTP frontends |
| VM-7 | 9090-9091 | HAProxy TCP frontends |
| VM-7 | 8404 | HAProxy stats UI |
| VM-7 | 9099 | Prometheus |
| VM-7 | 3000 | Grafana |

**DNS/Hosts**:
Все хосты должны резолвиться по именам (через `/etc/hosts` или DNS):
```
<VM-1-IP>  clickhouse-01
<VM-2-IP>  clickhouse-02
<VM-3-IP>  clickhouse-03
<VM-4-IP>  zookeeper-01
<VM-5-IP>  zookeeper-02
<VM-6-IP>  zookeeper-03
<VM-7-IP>  haproxy prometheus grafana
```

---

## Топология и конфигурация

### ClickHouse Cluster: `dwh_cluster`

**Конфигурация кластера** (одинакова на всех 3 нодах):

```xml
<remote_servers>
    <dwh_cluster>
        <shard>
            <internal_replication>true</internal_replication>
            <replica>
                <host>clickhouse-01</host>
                <port>9000</port>
            </replica>
            <replica>
                <host>clickhouse-02</host>
                <port>9000</port>
            </replica>
            <replica>
                <host>clickhouse-03</host>
                <port>9000</port>
            </replica>
        </shard>
    </dwh_cluster>
</remote_servers>
```

**Параметры**:
- `internal_replication=true` - данные реплицируются автоматически через ZooKeeper
- 1 шард = все данные на всех нодах (полная репликация)
- 3 реплики = отказоустойчивость

### Специализация нод

| Нода | Replica ID | Роль | Оптимизация |
|------|------------|------|-------------|
| clickhouse-01 | replica_01 | **ETL/Write** | Агрессивный merge, больше background threads |
| clickhouse-02 | replica_02 | **Analytics/Read** | Большие кэши, копирование готовых частей |
| clickhouse-03 | replica_03 | **Reports/Read** | Большие кэши, копирование готовых частей |

### ClickHouse Node-01 (Write-optimized)

**Файл**: `production-deployment/shared-configs/clickhouse-01/config.xml`

**Ключевые параметры**:

```xml
<!-- Память: 90% RAM для буферов и merges -->
<max_server_memory_usage_to_ram_ratio>0.9</max_server_memory_usage_to_ram_ratio>
<max_concurrent_queries>100</max_concurrent_queries>

<!-- Кэши: меньше для write-нагрузки -->
<mark_cache_size>5368709120</mark_cache_size>           <!-- 5 GB -->
<uncompressed_cache_size>10737418240</uncompressed_cache_size> <!-- 10 GB -->

<!-- Background операции: агрессивный merge -->
<background_pool_size>32</background_pool_size>
<background_schedule_pool_size>128</background_schedule_pool_size>
<background_merges_mutations_concurrency_ratio>4</background_merges_mutations_concurrency_ratio>

<!-- MergeTree: максимальные размеры для merge -->
<merge_tree>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>
    <max_replicated_merges_in_queue>32</max_replicated_merges_in_queue>
</merge_tree>
```

**Макросы**:
```xml
<macros>
    <shard>01</shard>
    <replica>replica_01</replica>
    <cluster>dwh_cluster</cluster>
</macros>
```

**Зачем такая конфигурация**:
- **32 background pools** - быстро мержит данные после INSERT
- **161 GB max merge size** - склеивает много мелких частей в большие
- **Меньше кэшей** - память идет на буферы вставки

### ClickHouse Node-02/03 (Read-optimized)

**Файлы**: `clickhouse-02/config.xml`, `clickhouse-03/config.xml`

**Ключевые параметры**:

```xml
<!-- Память: 85% RAM (больше для кэшей) -->
<max_server_memory_usage_to_ram_ratio>0.85</max_server_memory_usage_to_ram_ratio>
<max_concurrent_queries>150</max_concurrent_queries>

<!-- Кэши: удвоенные для read-нагрузки -->
<mark_cache_size>10737418240</mark_cache_size>          <!-- 10 GB -->
<uncompressed_cache_size>21474836480</uncompressed_cache_size> <!-- 20 GB -->

<!-- Background операции: ленивый merge -->
<background_pool_size>16</background_pool_size>
<background_schedule_pool_size>64</background_schedule_pool_size>
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>

<!-- MergeTree: копирование готовых частей вместо merge -->
<merge_tree>
    <max_bytes_to_merge_at_max_space_in_pool>107374182400</max_bytes_to_merge_at_max_space_in_pool>
    <max_replicated_merges_in_queue>16</max_replicated_merges_in_queue>
    <prefer_fetch_merged_part_size_threshold>536870912</prefer_fetch_merged_part_size_threshold>
</merge_tree>
```

**Зачем такая конфигурация**:
- **Больше кэшей** (10+20 GB) - ускоряют SELECT запросы
- **150 concurrent queries** - больше параллельных запросов
- **prefer_fetch_merged_part_size_threshold** - копируют готовые части с Node-01 вместо самостоятельного merge (экономят CPU для SELECT)

### ZooKeeper Configuration

**Конфигурация в ClickHouse** (одинакова на всех нодах):

```xml
<zookeeper>
    <node>
        <host>zookeeper-01</host>
        <port>2181</port>
    </node>
    <node>
        <host>zookeeper-02</host>
        <port>2181</port>
    </node>
    <node>
        <host>zookeeper-03</host>
        <port>2181</port>
    </node>
    <session_timeout_ms>30000</session_timeout_ms>
    <operation_timeout_ms>10000</operation_timeout_ms>
</zookeeper>

<distributed_ddl>
    <path>/clickhouse/task_queue/ddl</path>
</distributed_ddl>
```

**Docker Compose для каждой ZK ноды**:

Каждая нода ZooKeeper запускается на отдельной VM с параметрами:
```yaml
ZOO_MY_ID: 1, 2, 3  # Уникальный ID для каждой ноды
ZOO_SERVERS: server.1=zookeeper-01:2888:3888;2181 server.2=... server.3=...
ZOO_TICK_TIME: 2000
ZOO_INIT_LIMIT: 10
ZOO_SYNC_LIMIT: 5
```

**Роль ZooKeeper**:
- Координация репликации (кто leader, кто follower)
- Хранение метаданных о частях таблиц
- Distributed DDL (DDL выполняется на всех нодах кластера)

---

## Балансировка нагрузки

### HAProxy: интеллектуальная маршрутизация

**Файл**: `production-deployment/shared-configs/haproxy.cfg`

### Endpoints и стратегии

| Endpoint | Порт | Протокол | Назначение | Backend | Стратегия |
|----------|------|----------|------------|---------|-----------|
| ETL | 8080 | HTTP | Массовые INSERT | clickhouse-01 | `balance first` |
| ETL TCP | 9090 | TCP | Native INSERT | clickhouse-01 | `balance first` |
| Analytics | 8081 | HTTP | Быстрые SELECT | Все ноды | `balance leastconn` |
| Analytics TCP | 9091 | TCP | Native SELECT | Все ноды | `balance leastconn` |
| Reports | 8082 | HTTP | Тяжелые отчеты | Node-02/03 | `balance source` |
| Stats | 8404 | HTTP | Статистика HAProxy | - | - |

### Стратегия 1: ETL (8080, 9090)

```cfg
backend clickhouse_etl_http
    mode http
    balance first  # Всегда первый доступный сервер
    timeout server 600s  # 10 минут для batch INSERT

    server clickhouse-01 clickhouse-01:8123 check
    server clickhouse-02 clickhouse-02:8123 check backup
    server clickhouse-03 clickhouse-03:8123 check backup
```

**Как работает**:
1. Все INSERT идут на **clickhouse-01** (write-optimized)
2. Node-02/03 помечены как `backup` → включаются только если Node-01 down
3. Node-01 мержит данные → Node-02/03 копируют готовые части

**Преимущества**:
- INSERT изолирован от SELECT (не блокирует аналитику)
- Node-01 сфокусирован на быстрых merges
- При падении Node-01 запись переключается на Node-02

### Стратегия 2: Analytics (8081, 9091)

```cfg
backend clickhouse_analytics_http
    mode http
    balance leastconn  # Наименьшее число активных соединений
    timeout server 30s  # Быстрые запросы

    server clickhouse-01 clickhouse-01:8123 check
    server clickhouse-02 clickhouse-02:8123 check
    server clickhouse-03 clickhouse-03:8123 check
```

**Как работает**:
1. Запрос идет на ноду с **минимальным числом активных подключений**
2. Равномерная нагрузка на все 3 ноды
3. Короткий timeout (30s) для быстрых запросов

**Преимущества**:
- Максимальная параллелизация (3 ноды обрабатывают запросы)
- Автоматическое выравнивание нагрузки
- Отказоустойчивость при падении любой ноды

### Стратегия 3: Reports (8082)

```cfg
backend clickhouse_reports_http
    mode http
    balance source  # Hash от IP клиента
    timeout server 1800s  # 30 минут для тяжелых отчетов

    server clickhouse-02 clickhouse-02:8123 check
    server clickhouse-03 clickhouse-03:8123 check
    server clickhouse-01 clickhouse-01:8123 check backup
```

**Как работает**:
1. Один клиент всегда попадает на одну ноду (hash IP адреса)
2. Приоритет на **Node-02/03** (read-optimized, большие кэши)
3. Node-01 только как резервный (освобожден для ETL)

**Преимущества**:
- Стабильность для долгих запросов (один клиент = одна нода)
- Кэширование результатов на уровне ноды
- Не мешает ETL (Node-01 в backup)

### Health Checks

```cfg
option httpchk GET /ping
http-check expect status 200
check inter 2000 rise 2 fall 3
```

**Параметры**:
- Проверка каждые **2 секунды**
- **2 успешных проверки** → нода UP
- **3 провала** → нода DOWN

---

## Управление пользователями (RBAC)

### Концепция

В кластере используется **SQL-based Access Control** вместо XML конфигурации.

**Преимущества**:
- Создание пользователей без перезапуска ClickHouse
- Гранулярные права (таблица, колонка, строка)
- Репликация через ZooKeeper (команды `ON CLUSTER`)
- Аудит всех изменений в `system.query_log`

### Начальная настройка

**Пользователи в users.xml** (только для bootstrap):

```xml
<users>
    <default>
        <password></password>
        <networks><ip>127.0.0.1</ip></networks>
        <!-- Только localhost, для внутренних нужд -->
    </default>

    <admin>
        <password>CHANGE_ME_BEFORE_DEPLOY</password>
        <networks><ip>::/0</ip></networks>
        <profile>admin_profile</profile>
        <access_management>1</access_management>
        <!-- Полные права + управление пользователями -->
    </admin>
</users>
```

⚠️ **ВАЖНО**: Изменить пароль `admin` сразу после развертывания!

### Создание ролей

Подключиться как admin:
```bash
clickhouse-client -h haproxy --port 9090 --user admin --password <password>
```

**Роль для ETL (запись)**:
```sql
CREATE ROLE etl_role ON CLUSTER dwh_cluster;

GRANT CREATE TABLE ON *.* TO etl_role;
GRANT INSERT ON *.* TO etl_role;
GRANT SELECT ON *.* TO etl_role;  -- Для проверки данных
GRANT SELECT ON system.* TO etl_role;
```

**Роль для аналитики (чтение)**:
```sql
CREATE ROLE analytics_role ON CLUSTER dwh_cluster;

GRANT SELECT ON *.* TO analytics_role;
GRANT SELECT ON system.* TO analytics_role;
```

**Роль для отчетов (тяжелые запросы)**:
```sql
CREATE ROLE reports_role ON CLUSTER dwh_cluster;

GRANT SELECT ON *.* TO reports_role;
GRANT CREATE TEMPORARY TABLE ON *.* TO reports_role;
GRANT SELECT ON system.* TO reports_role;
```

### Создание пользователей

**ETL пользователь**:
```sql
CREATE USER etl_user ON CLUSTER dwh_cluster
IDENTIFIED WITH sha256_password BY 'strong_password_here'
SETTINGS
    max_memory_usage = 50000000000,      -- 50 GB
    max_execution_time = 3600,           -- 1 час
    max_insert_threads = 16,
    async_insert = 1,
    max_threads = 32;

GRANT etl_role TO etl_user ON CLUSTER dwh_cluster;
```

**Analytics пользователь**:
```sql
CREATE USER analytics_user ON CLUSTER dwh_cluster
IDENTIFIED WITH sha256_password BY 'strong_password_here'
SETTINGS
    readonly = 1,
    max_memory_usage = 10000000000,      -- 10 GB
    max_execution_time = 300,            -- 5 минут
    max_threads = 16;

GRANT analytics_role TO analytics_user ON CLUSTER dwh_cluster;
```

**Reports пользователь**:
```sql
CREATE USER reports_user ON CLUSTER dwh_cluster
IDENTIFIED WITH sha256_password BY 'strong_password_here'
SETTINGS
    readonly = 1,
    max_memory_usage = 30000000000,      -- 30 GB
    max_execution_time = 1800,           -- 30 минут
    max_threads = 24,
    max_bytes_in_join = 10000000000;

GRANT reports_role TO reports_user ON CLUSTER dwh_cluster;
```

### Проверка

```sql
-- Список пользователей
SHOW USERS;

-- Права пользователя
SHOW GRANTS FOR etl_user;

-- Активные сессии
SELECT user, query_id, query, elapsed
FROM system.processes;
```

---

## Мониторинг и метрики

### Grafana Dashboards

**Доступ**: `http://<VM-7-IP>:3000`
**Login**: `admin` / `admin123` (изменить после первого входа!)

**Рекомендуемые дашборды** (импортировать по ID):
- **ClickHouse Overview**: ID `14192`
- **ClickHouse Query Analysis**: ID `14999`
- **HAProxy**: ID `12693`

### Ключевые метрики

**Производительность**:
```promql
# Запросов в секунду
rate(ClickHouseProfileEvents_Query[1m])

# INSERT строк в секунду
rate(ClickHouseProfileEvents_InsertedRows[1m])

# SELECT запросов в секунду
rate(ClickHouseProfileEvents_SelectQuery[1m])
```

**Ресурсы**:
```promql
# Использование памяти (байты)
ClickHouseMetrics_MemoryTracking

# Активные background задачи
ClickHouseMetrics_BackgroundPoolTask

# Активные merges
ClickHouseMetrics_BackgroundMergesAndMutationsPoolTask
```

**Репликация**:
```promql
# Размер очереди репликации
ClickHouseMetrics_ReplicationQueue

# Fetch операций (копирование частей)
ClickHouseMetrics_ReplicatedFetch
```

**Ошибки**:
```promql
# Проваленные запросы в секунду
rate(ClickHouseProfileEvents_FailedQuery[1m])

# Проваленные INSERT
rate(ClickHouseProfileEvents_FailedInsertQuery[1m])
```

### Query Log анализ

**Медленные запросы (>10 сек)**:
```sql
SELECT
    query_start_time,
    query_duration_ms / 1000 as duration_sec,
    user,
    query,
    read_rows,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(memory_usage) as memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000
ORDER BY query_start_time DESC
LIMIT 100;
```

**Проваленные запросы**:
```sql
SELECT
    query_start_time,
    user,
    query,
    exception
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
ORDER BY query_start_time DESC
LIMIT 100;
```

---

## Производительность и оптимизация

### Пропускная способность

**На основе вашей конфигурации (16-32 cores, 64-128 GB RAM)**:

| Операция | Производительность | Примечания |
|----------|-------------------|------------|
| **INSERT** (простые таблицы) | 2-5M строк/сек | Через ETL endpoint (8080) |
| **INSERT** (сложные таблицы) | 500K-2M строк/сек | С индексами, материализованными колонками |
| **SELECT** (простые агрегации) | <100ms | COUNT, SUM по индексу |
| **SELECT** (сложные агрегации) | 1-10 сек | GROUP BY по 10+ колонкам |
| **Full scan** | ~10B строк/сек | На одну ноду, без индексов |
| **Параллельные запросы** | 300-500 | Analytics endpoint (8081) |
| **JOIN** (small) | <1 сек | <1M строк |
| **JOIN** (large) | 10-60 сек | 100M-1B строк |

### Оптимизация таблиц

**Рекомендуемая структура**:

```sql
CREATE TABLE events ON CLUSTER dwh_cluster (
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    event_type LowCardinality(String),
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_time)
SETTINGS index_granularity = 8192;
```

**Best practices**:
- **ENGINE**: `ReplicatedMergeTree` для всех таблиц в кластере
- **PARTITION BY**:
  - `toYYYYMM(date)` для таблиц 100M-1B строк
  - `toYear(date)` для малых таблиц (<100M)
  - `toMonday(date)` для очень больших таблиц (>1B)
- **ORDER BY**: Часто фильтруемые колонки в начале
- **LowCardinality**: Для колонок с <10K уникальных значений
- **Compression**: ZSTD level 3 (по умолчанию в конфигах)

### Партиционирование

**Стратегия для ваших таблиц**:

| Размер таблицы | PARTITION BY | Причина |
|----------------|--------------|---------|
| 2B строк (2 большие таблицы) | `toYYYYMM(date)` | ~24 партиции за 2 года, легко удалять старые месяцы |
| 50-200M строк | `toYYYYMM(date)` | Баланс между кол-вом партиций и размером |
| <10M строк | `toYear(date)` | Не нужно дробить на месяцы |

**Пример**:
```sql
-- Для большой таблицы (2B строк)
PARTITION BY toYYYYMM(event_date)

-- Удаление старой партиции (целиком, очень быстро)
ALTER TABLE events DROP PARTITION '202301';
```

### Skip Indexes

**Для ускорения фильтрации**:

```sql
-- Индекс по строковому полю (set)
ALTER TABLE events ADD INDEX idx_event_type event_type TYPE set(100) GRANULARITY 4;

-- Bloom filter для LIKE запросов
ALTER TABLE events ADD INDEX idx_url url TYPE bloom_filter GRANULARITY 4;

-- Materialize индекс (применяется к существующим данным)
ALTER TABLE events MATERIALIZE INDEX idx_event_type;
```

---

## Резервное копирование

### Стратегия 1: ClickHouse BACKUP (рекомендуется)

**Полный бэкап всех баз**:
```sql
BACKUP DATABASE dwh TO Disk('backups', 'backup_2024_10_01.zip');
```

**Восстановление**:
```sql
RESTORE DATABASE dwh FROM Disk('backups', 'backup_2024_10_01.zip');
```

**Автоматизация** (cron на любой VM):
```bash
#!/bin/bash
# /opt/scripts/clickhouse_backup.sh

DATE=$(date +%Y_%m_%d)
BACKUP_NAME="backup_${DATE}.zip"

clickhouse-client -h haproxy --port 9090 --user admin --password <password> --query \
"BACKUP DATABASE dwh TO Disk('backups', '${BACKUP_NAME}')"

# Удалить бэкапы старше 7 дней
find /backups -name "backup_*.zip" -mtime +7 -delete
```

Добавить в crontab:
```
0 2 * * * /opt/scripts/clickhouse_backup.sh
```

### Стратегия 2: Volume Snapshot

**Для VM в облаке** (AWS EBS, GCP Persistent Disk):
```bash
# Остановить контейнер
docker stop clickhouse-01

# Создать snapshot диска
aws ec2 create-snapshot --volume-id vol-xxxxx --description "ClickHouse backup"

# Запустить контейнер
docker start clickhouse-01
```

### Disaster Recovery

**Сценарий 1: Потеря одной ноды ClickHouse**
1. Кластер продолжает работать (2 ноды остались)
2. Развернуть новую VM
3. Запустить ClickHouse с той же конфигурацией
4. Данные автоматически реплицируются с других нод

**Сценарий 2: Потеря всех нод ClickHouse**
1. Восстановить ZooKeeper (если потерян)
2. На одной ноде восстановить из бэкапа:
   ```sql
   RESTORE DATABASE dwh FROM Disk('backups', 'latest.zip');
   ```
3. Запустить остальные ноды - данные реплицируются

**Сценарий 3: Потеря ZooKeeper кворума**
1. Если потеряны 2+ ноды ZK → кластер не работает
2. Восстановить ZK из snapshot (`/data/version-2/`)
3. Перезапустить ClickHouse ноды

---

## Troubleshooting

### Проблема: Реплики не синхронизируются

**Симптом**: Данные есть на Node-01, но нет на Node-02/03

**Диагностика**:
```sql
-- Проверить очередь репликации
SELECT
    database, table,
    num_tries,
    last_exception
FROM system.replication_queue
WHERE num_tries > 10;

-- Проверить статус реплик
SELECT
    database, table,
    is_leader,
    total_replicas,
    active_replicas
FROM system.replicas;
```

**Решение**:
```sql
-- Принудительно синхронизировать
SYSTEM SYNC REPLICA events;

-- Если не помогает - пересоздать реплику
SYSTEM DROP REPLICA 'replica_02' FROM TABLE events;
-- На Node-02: пересоздать таблицу
```

### Проблема: ZooKeeper недоступен

**Симптом**: `Coordination::Exception: Session expired`

**Диагностика**:
```bash
# Проверить статус ZK
docker exec zookeeper-01 zkServer.sh status

# Проверить подключение
echo ruok | nc zookeeper-01 2181
# Должно вернуть: imok
```

**Решение**:
```bash
# Перезапустить ZK ноду
docker restart zookeeper-01

# Увеличить session timeout в config.xml
<session_timeout_ms>60000</session_timeout_ms>  <!-- было 30000 -->
```

### Проблема: Медленные запросы

**Диагностика**:
```sql
-- Найти медленные запросы
SELECT
    query_start_time,
    query_duration_ms / 1000 as duration_sec,
    user,
    substring(query, 1, 100) as query_short,
    read_rows,
    formatReadableSize(read_bytes) as read_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- Включить подробное логирование
SET send_logs_level = 'trace';
```

**Решение**:
- Добавить skip indexes
- Оптимизировать ORDER BY в таблице
- Добавить материализованные колонки
- Увеличить `max_threads` для запроса

### Проблема: Out of Memory

**Диагностика**:
```sql
-- Проверить использование памяти
SELECT
    user,
    formatReadableSize(sum(memory_usage)) as total_memory,
    count() as queries
FROM system.processes
GROUP BY user;
```

**Решение**:
```sql
-- Убить тяжелый запрос
KILL QUERY WHERE query_id = 'xxx';

-- Увеличить лимит для пользователя
ALTER USER reports_user SETTINGS max_memory_usage = 50000000000;
```

### Проблема: HAProxy backend DOWN

**Диагностика**:
```bash
# Проверить HAProxy stats
curl http://<VM-7-IP>:8404

# Проверить health check вручную
curl http://clickhouse-01:8123/ping
```

**Решение**:
```bash
# Проверить firewall
sudo ufw status

# Проверить ClickHouse работает
docker ps
docker logs clickhouse-01

# Вручную поднять backend
echo "set server clickhouse_etl_http/clickhouse-01 state ready" | \
  docker exec -i haproxy socat stdio /var/run/haproxy.sock
```

---

## Масштабирование

### Вертикальное (scale up)

Увеличение ресурсов существующих VM:
- CPU: 32 → 64 cores
- RAM: 128 → 256 GB
- Disk: 2 TB → 4-8 TB

**Когда**: Не хватает производительности на текущих нодах

### Горизонтальное (scale out)

Добавление новых шардов (когда данных очень много):

```xml
<remote_servers>
    <dwh_cluster>
        <!-- Существующий шард-1 -->
        <shard>
            <internal_replication>true</internal_replication>
            <replica><host>clickhouse-01</host></replica>
            <replica><host>clickhouse-02</host></replica>
            <replica><host>clickhouse-03</host></replica>
        </shard>

        <!-- Новый шард-2 -->
        <shard>
            <internal_replication>true</internal_replication>
            <replica><host>clickhouse-04</host></replica>
            <replica><host>clickhouse-05</host></replica>
            <replica><host>clickhouse-06</host></replica>
        </shard>
    </dwh_cluster>
</remote_servers>
```

Пересоздать таблицы с `Distributed` движком:
```sql
CREATE TABLE events_distributed ON CLUSTER dwh_cluster AS events
ENGINE = Distributed(dwh_cluster, default, events, rand());
```

**Когда**: Данных >20 TB, нужна горизонтальная партиционированность

---

## Ссылки и поддержка

**Документация**:
- ClickHouse: https://clickhouse.com/docs
- HAProxy: https://www.haproxy.org/
- Prometheus: https://prometheus.io/docs/

**Community**:
- ClickHouse Slack: https://clickhouse.com/slack
- GitHub: https://github.com/ClickHouse/ClickHouse

---

## Changelog

| Версия | Дата | Изменения |
|--------|------|-----------|
| 2.0 | 2024-10-01 | Переписана для production (убраны dev конфиги, фокус на VM deployment) |
| 1.0 | 2024-10-01 | Начальная версия |
