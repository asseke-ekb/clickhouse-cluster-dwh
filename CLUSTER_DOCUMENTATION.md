# ClickHouse DWH Cluster - Документация

## Оглавление
1. [Обзор архитектуры](#обзор-архитектуры)
2. [Требования к инфраструктуре](#требования-к-инфраструктуре)
3. [Топология кластера](#топология-кластера)
4. [Конфигурация компонентов](#конфигурация-компонентов)
5. [Балансировка нагрузки](#балансировка-нагрузки)
6. [Развертывание](#развертывание)
7. [Управление пользователями и RBAC](#управление-пользователями-и-rbac)
8. [Мониторинг](#мониторинг)
9. [Производительность](#производительность)
10. [Резервное копирование](#резервное-копирование)
11. [Troubleshooting](#troubleshooting)

---

## Обзор архитектуры

Отказоустойчивый кластер ClickHouse для построения Data Warehouse с полным стеком мониторинга и интеллектуальной балансировкой нагрузки.

### Ключевые характеристики
- **Топология**: 1 шард, 3 реплики (полная репликация данных)
- **Отказоустойчивость**: Работа при падении до 1 ноды ClickHouse и 1 ноды ZooKeeper
- **Разделение нагрузки**: ETL/запись, аналитика, тяжелые отчеты
- **Мониторинг**: Prometheus + Grafana
- **Версии**: ClickHouse 24.3, ZooKeeper 3.8, HAProxy 2.8

### Архитектурная диаграмма
```
                    ┌──────────────┐
                    │   HAProxy    │
                    │  Load Balancer│
                    └──────┬───────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│ ClickHouse-01 │  │ ClickHouse-02 │  │ ClickHouse-03 │
│ (Write-heavy) │  │ (Read-heavy)  │  │ (Read-heavy)  │
│ replica_01    │  │ replica_02    │  │ replica_03    │
└───────┬───────┘  └───────┬───────┘  └───────┬───────┘
        │                  │                  │
        └──────────────────┼──────────────────┘
                           │
                ┌──────────┴──────────┐
                │  ZooKeeper Ensemble  │
                │   (3 ноды, quorum)   │
                └─────────────────────┘
```

---

## Требования к инфраструктуре

### Вариант 3: Продакшн-окружение (рекомендуемый)

#### Виртуальные машины

##### VM-1, VM-2, VM-3: ClickHouse Nodes
```yaml
Количество: 3 VM
CPU: 16-32 cores (физических)
RAM: 64-128 GB
Disk: 2-4 TB NVMe SSD (RAID10 для надежности)
Network: 10 Gbps
OS: Ubuntu 22.04 LTS или RHEL 8+
```

##### VM-4, VM-5, VM-6: ZooKeeper Nodes
```yaml
Количество: 3 VM
CPU: 4 cores
RAM: 8 GB
Disk: 100 GB SSD
Network: 1 Gbps
OS: Ubuntu 22.04 LTS или RHEL 8+
```

##### VM-7: HAProxy + Monitoring
```yaml
Количество: 1 VM
CPU: 4-8 cores
RAM: 16 GB
Disk: 200 GB SSD
Network: 10 Gbps
OS: Ubuntu 22.04 LTS
```

#### Сетевые требования
- **Внутренняя сеть**: Выделенная VLAN между всеми нодами (низкая latency <1ms)
- **Firewall правила**: См. раздел [Сетевая безопасность](#сетевая-безопасность)
- **DNS**: Все хосты должны резолвиться по именам (clickhouse-01, clickhouse-02, и т.д.)

#### Расчет ресурсов под текущую нагрузку

**Данные**:
- История: ~5 млрд записей (2.4 TB с репликацией)
- Прирост: 1.5M - 8M строк/день (~840 GB/год с репликацией)
- Таблиц: 15-20 в stage0

**Хранилище**:
- Текущие данные: 2.4 TB
- Прирост за 2 года: +1.68 TB
- Итого через 2 года: ~4 TB
- **Рекомендация**: 2 TB на ноду (6 TB суммарно), расширение через 2-3 года

**Производительность**:
- INSERT: 17-92 строки/сек (легкая нагрузка для кластера)
- SELECT (analytics): 200-500 одновременных запросов
- SELECT (reports): 10-50 тяжелых запросов

---

## Топология кластера

### ClickHouse Cluster Configuration

**Имя кластера**: `dwh_cluster`
**Шарды**: 1
**Реплики на шард**: 3

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

### Специализация нод

| Нода | Replica ID | Роль | Оптимизация |
|------|------------|------|-------------|
| clickhouse-01 | replica_01 | ETL/Write | Агрессивный merge, больше background pools |
| clickhouse-02 | replica_02 | Analytics/Read | Большие кэши, копирование готовых частей |
| clickhouse-03 | replica_03 | Reports/Read | Большие кэши, копирование готовых частей |

---

## Конфигурация компонентов

### ClickHouse Node-01 (Write-optimized)

**IP**: `<VM-1-IP>`
**Hostname**: `clickhouse-01`

#### Сетевые порты
- `8123` - HTTP API
- `9000` - Native TCP protocol
- `9009` - Interserver HTTP (репликация)
- `9363` - Prometheus metrics

#### Ключевые параметры конфигурации
```xml
<!-- config/clickhouse-01/config.xml -->

<!-- Память -->
<max_server_memory_usage_to_ram_ratio>0.9</max_server_memory_usage_to_ram_ratio>
<max_concurrent_queries>100</max_concurrent_queries>

<!-- Кэши (меньше для write-нагрузки) -->
<mark_cache_size>5368709120</mark_cache_size>           <!-- 5 GB -->
<uncompressed_cache_size>10737418240</uncompressed_cache_size> <!-- 10 GB -->

<!-- Background операции (агрессивный merge) -->
<background_pool_size>32</background_pool_size>
<background_schedule_pool_size>128</background_schedule_pool_size>
<background_merges_mutations_concurrency_ratio>4</background_merges_mutations_concurrency_ratio>

<!-- MergeTree настройки -->
<merge_tree>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>
    <max_replicated_merges_in_queue>32</max_replicated_merges_in_queue>
</merge_tree>

<!-- Kafka (если используется) -->
<kafka>
    <kafka_poll_timeout_ms>5000</kafka_poll_timeout_ms>
    <kafka_flush_interval_ms>7500</kafka_flush_interval_ms>
</kafka>
```

#### Макросы
```xml
<macros>
    <shard>01</shard>
    <replica>replica_01</replica>
    <cluster>dwh_cluster</cluster>
</macros>
```

---

### ClickHouse Node-02/03 (Read-optimized)

**Node-02 IP**: `<VM-2-IP>`
**Node-03 IP**: `<VM-3-IP>`
**Hostname**: `clickhouse-02`, `clickhouse-03`

#### Ключевые параметры конфигурации
```xml
<!-- config/clickhouse-02/config.xml, config/clickhouse-03/config.xml -->

<!-- Память -->
<max_server_memory_usage_to_ram_ratio>0.85</max_server_memory_usage_to_ram_ratio>
<max_concurrent_queries>150</max_concurrent_queries>

<!-- Кэши (больше для read-нагрузки) -->
<mark_cache_size>10737418240</mark_cache_size>          <!-- 10 GB -->
<uncompressed_cache_size>21474836480</uncompressed_cache_size> <!-- 20 GB -->

<!-- Background операции (ленивый merge) -->
<background_pool_size>16</background_pool_size>
<background_schedule_pool_size>64</background_schedule_pool_size>
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>

<!-- MergeTree настройки -->
<merge_tree>
    <max_bytes_to_merge_at_max_space_in_pool>107374182400</max_bytes_to_merge_at_max_space_in_pool>
    <max_replicated_merges_in_queue>16</max_replicated_merges_in_queue>
    <!-- Копировать готовые части с Node-01 вместо самостоятельного merge -->
    <prefer_fetch_merged_part_size_threshold>536870912</prefer_fetch_merged_part_size_threshold>
</merge_tree>
```

#### Макросы
```xml
<!-- Node-02 -->
<macros>
    <shard>01</shard>
    <replica>replica_02</replica>
    <cluster>dwh_cluster</cluster>
</macros>

<!-- Node-03 -->
<macros>
    <shard>01</shard>
    <replica>replica_03</replica>
    <cluster>dwh_cluster</cluster>
</macros>
```

---

### ZooKeeper Ensemble

**Ноды**: 3 (обеспечивают quorum)

| Hostname | IP | Client Port | Peer Port | Election Port |
|----------|-----|-------------|-----------|---------------|
| zookeeper-01 | `<VM-4-IP>` | 2181 | 2888 | 3888 |
| zookeeper-02 | `<VM-5-IP>` | 2181 | 2888 | 3888 |
| zookeeper-03 | `<VM-6-IP>` | 2181 | 2888 | 3888 |

#### Конфигурация в ClickHouse
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
```

#### Параметры ZooKeeper
```
ZOO_MY_ID: 1, 2, 3 (для каждой ноды соответственно)
ZOO_TICK_TIME: 2000
ZOO_INIT_LIMIT: 10
ZOO_SYNC_LIMIT: 5
ZOO_MAX_CLIENT_CNXNS: 0 (без ограничений)
```

---

### HAProxy Load Balancer

**Hostname**: `haproxy`
**IP**: `<VM-7-IP>`

#### Endpoints и порты

| Endpoint | Порт | Протокол | Назначение | Backend |
|----------|------|----------|------------|---------|
| ETL | 8080 | HTTP | Массовые INSERT | clickhouse-01 (priority) |
| ETL TCP | 9090 | TCP | Native protocol INSERT | clickhouse-01 (priority) |
| Analytics | 8081 | HTTP | Быстрые SELECT | Все ноды (leastconn) |
| Analytics TCP | 9091 | TCP | Native protocol SELECT | Все ноды (leastconn) |
| Reports | 8082 | HTTP | Тяжелые отчеты | Node-02/03 (source hash) |
| Stats UI | 8404 | HTTP | HAProxy статистика | - |

#### Стратегии балансировки

**ETL (8080, 9090)**:
```
balance first
server clickhouse-01 primary
server clickhouse-02 backup
server clickhouse-03 backup
timeout server 600s
```
- Всегда использует Node-01
- Node-02/03 только при падении Node-01
- Длинный timeout для batch INSERT

**Analytics (8081, 9091)**:
```
balance leastconn
server clickhouse-01
server clickhouse-02
server clickhouse-03
timeout server 30s
```
- Равномерное распределение по нагрузке
- Выбирает ноду с минимумом активных соединений

**Reports (8082)**:
```
balance source
server clickhouse-02
server clickhouse-03
server clickhouse-01 backup
timeout server 1800s
```
- Клиент всегда попадает на одну ноду (hash IP)
- Node-01 только как резервный
- Очень длинный timeout (30 минут)

#### Health Checks
```
option httpchk GET /ping
http-check expect status 200
check inter 2000 rise 2 fall 3
```
- Проверка каждые 2 секунды
- 2 успешных проверки → нода "вверх"
- 3 провала → нода "вниз"

---

### Prometheus

**Hostname**: `prometheus`
**IP**: `<VM-7-IP>`
**Порт**: 9099

#### Targets (что мониторится)
- ClickHouse-01: `http://clickhouse-01:9363/metrics`
- ClickHouse-02: `http://clickhouse-02:9363/metrics`
- ClickHouse-03: `http://clickhouse-03:9363/metrics`
- HAProxy: `http://haproxy:8404/stats` (через exporter)

#### Retention
- Хранение метрик: 30 дней
- Path: `/prometheus` (persistent volume)

---

### Grafana

**Hostname**: `grafana`
**IP**: `<VM-7-IP>`
**Порт**: 3000

#### Credentials
- **Username**: `admin`
- **Password**: `admin123` ⚠️ **ИЗМЕНИТЬ ПОСЛЕ УСТАНОВКИ**

#### Datasources
- Prometheus: `http://prometheus:9090`
- ClickHouse: `http://clickhouse-01:8123` (через плагин grafana-clickhouse-datasource)

---

## Балансировка нагрузки

### Принцип работы

#### 1. Разделение по типу нагрузки

**Почему важно**:
- INSERT блокирует части таблицы → мешает SELECT
- Тяжелые JOIN нагружают CPU → замедляют быстрые запросы
- Разные типы запросов требуют разных ресурсов

**Решение**:
- ETL → Node-01 (изолирован от read-нагрузки)
- Analytics → Все ноды (параллелизм)
- Reports → Node-02/03 (не мешают ETL)

#### 2. Оптимизация конфигураций

**Node-01 (Write)**:
- ✅ Агрессивно мержит данные сразу после INSERT
- ✅ Больше потоков для background операций
- ✅ Меньше кэшей (память для буферов вставки)
- ❌ Не оптимален для чтения (части еще не смержены)

**Node-02/03 (Read)**:
- ✅ Копируют готовые смерженные части с Node-01
- ✅ Большие кэши для ускорения SELECT
- ✅ Больше параллельных запросов
- ❌ Не оптимальны для записи (меньше merge потоков)

#### 3. Репликация

**Механизм**:
1. INSERT приходит на Node-01 через HAProxy (порт 8080)
2. Node-01 записывает данные локально
3. ZooKeeper фиксирует операцию в логе репликации
4. Node-02 и Node-03 получают уведомление от ZK
5. Node-02/03 копируют данные (или готовые части) с Node-01

**Консистентность**:
- `internal_replication=true` → данные реплицируются автоматически
- Кворум ZooKeeper (2 из 3 нод) → защита от split-brain
- Все реплики имеют одинаковые данные (eventual consistency)

---

## Развертывание

### Подготовка инфраструктуры

#### 1. Создание виртуальных машин

```bash
# Пример для VMware/Proxmox/OpenStack
# Создать 7 VM согласно спецификации выше
```

#### 2. Настройка DNS/Hosts

На **всех 7 VM** добавить в `/etc/hosts`:

```bash
# ClickHouse Nodes
<VM-1-IP>  clickhouse-01
<VM-2-IP>  clickhouse-02
<VM-3-IP>  clickhouse-03

# ZooKeeper Nodes
<VM-4-IP>  zookeeper-01
<VM-5-IP>  zookeeper-02
<VM-6-IP>  zookeeper-03

# HAProxy + Monitoring
<VM-7-IP>  haproxy prometheus grafana
```

#### 3. Настройка Firewall

**На VM-1, VM-2, VM-3 (ClickHouse)**:
```bash
# ClickHouse порты
sudo firewall-cmd --permanent --add-port=8123/tcp  # HTTP API
sudo firewall-cmd --permanent --add-port=9000/tcp  # Native protocol
sudo firewall-cmd --permanent --add-port=9009/tcp  # Interserver
sudo firewall-cmd --permanent --add-port=9363/tcp  # Prometheus metrics
sudo firewall-cmd --reload
```

**На VM-4, VM-5, VM-6 (ZooKeeper)**:
```bash
sudo firewall-cmd --permanent --add-port=2181/tcp  # Client
sudo firewall-cmd --permanent --add-port=2888/tcp  # Peer
sudo firewall-cmd --permanent --add-port=3888/tcp  # Election
sudo firewall-cmd --reload
```

**На VM-7 (HAProxy)**:
```bash
sudo firewall-cmd --permanent --add-port=8080-8082/tcp  # HAProxy frontends
sudo firewall-cmd --permanent --add-port=8404/tcp       # Stats
sudo firewall-cmd --permanent --add-port=9090-9091/tcp  # TCP frontends
sudo firewall-cmd --permanent --add-port=9099/tcp       # Prometheus
sudo firewall-cmd --permanent --add-port=3000/tcp       # Grafana
sudo firewall-cmd --reload
```

#### 4. Установка Docker и Docker Compose

На **всех VM**:

```bash
# Ubuntu 22.04
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Добавить Docker GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Добавить репозиторий
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Установить Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Проверить установку
docker --version
docker compose version
```

---

### Развертывание компонентов

#### VM-4, VM-5, VM-6: ZooKeeper Nodes

**На каждой VM создать docker-compose.yml**:

**VM-4 (zookeeper-01)**:
```yaml
version: '3.8'

networks:
  clickhouse-net:
    driver: bridge

volumes:
  zookeeper-data:

services:
  zookeeper:
    image: zookeeper:3.8
    container_name: zookeeper-01
    hostname: zookeeper-01
    networks:
      - clickhouse-net
    ports:
      - "2181:2181"
      - "2888:2888"
      - "3888:3888"
    environment:
      ZOO_MY_ID: 1
      ZOO_SERVERS: server.1=0.0.0.0:2888:3888;2181 server.2=zookeeper-02:2888:3888;2181 server.3=zookeeper-03:2888:3888;2181
      ZOO_TICK_TIME: 2000
      ZOO_INIT_LIMIT: 10
      ZOO_SYNC_LIMIT: 5
      ZOO_MAX_CLIENT_CNXNS: 0
    volumes:
      - zookeeper-data:/data
      - ./logs:/datalog
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "zkServer.sh", "status"]
      interval: 10s
      timeout: 5s
      retries: 3
```

**VM-5 (zookeeper-02)**: Изменить `ZOO_MY_ID: 2`, hostname, container_name

**VM-6 (zookeeper-03)**: Изменить `ZOO_MY_ID: 3`, hostname, container_name

Запустить:
```bash
sudo docker compose up -d
```

---

#### VM-1, VM-2, VM-3: ClickHouse Nodes

**Подготовка конфигураций**:

1. Скопировать файлы из репозитория на каждую VM:
   - `config/clickhouse-0X/config.xml`
   - `config/users.xml`

2. Создать структуру:
```bash
mkdir -p /opt/clickhouse/config
mkdir -p /opt/clickhouse/logs
```

**VM-1 (clickhouse-01)**:
```yaml
version: '3.8'

networks:
  clickhouse-net:
    driver: bridge

volumes:
  clickhouse-data:

services:
  clickhouse:
    image: clickhouse/clickhouse-server:24.3
    container_name: clickhouse-01
    hostname: clickhouse-01
    networks:
      - clickhouse-net
    ports:
      - "8123:8123"
      - "9000:9000"
      - "9009:9009"
      - "9363:9363"
    volumes:
      - clickhouse-data:/var/lib/clickhouse
      - /opt/clickhouse/config/config.xml:/etc/clickhouse-server/config.d/config.xml
      - /opt/clickhouse/config/users.xml:/etc/clickhouse-server/users.d/users.xml
      - /opt/clickhouse/logs:/var/log/clickhouse-server
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "clickhouse-client", "--query", "SELECT 1"]
      interval: 10s
      timeout: 5s
      retries: 5
```

**VM-2, VM-3**: Аналогично, изменить hostname, container_name, конфиг файл

Запустить:
```bash
sudo docker compose up -d
```

---

#### VM-7: HAProxy + Prometheus + Grafana

**Структура**:
```bash
mkdir -p /opt/haproxy/config
mkdir -p /opt/prometheus/config
mkdir -p /opt/grafana/provisioning
```

**docker-compose.yml**:
```yaml
version: '3.8'

networks:
  clickhouse-net:
    driver: bridge

volumes:
  prometheus-data:
  grafana-data:

services:
  haproxy:
    image: haproxy:2.8
    container_name: haproxy
    hostname: haproxy
    networks:
      - clickhouse-net
    ports:
      - "8080:8080"
      - "8081:8081"
      - "8082:8082"
      - "8404:8404"
      - "9090:9090"
      - "9091:9091"
    volumes:
      - /opt/haproxy/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "haproxy", "-c", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
      interval: 10s
      timeout: 5s
      retries: 3

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    hostname: prometheus
    networks:
      - clickhouse-net
    ports:
      - "9099:9090"
    volumes:
      - /opt/prometheus/config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    hostname: grafana
    networks:
      - clickhouse-net
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
      - /opt/grafana/provisioning:/etc/grafana/provisioning
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin123
      GF_INSTALL_PLUGINS: grafana-clickhouse-datasource
      GF_USERS_ALLOW_SIGN_UP: false
    restart: unless-stopped
```

Запустить:
```bash
sudo docker compose up -d
```

---

### Проверка развертывания

#### 1. Проверить статус контейнеров

```bash
# На каждой VM
docker ps

# Все контейнеры должны быть "healthy" или "Up"
```

#### 2. Проверить кластер ClickHouse

```bash
# Подключиться к любой ноде ClickHouse
docker exec -it clickhouse-01 clickhouse-client

# Проверить кластер
SELECT * FROM system.clusters WHERE cluster = 'dwh_cluster';

# Должно показать 3 реплики в 1 шарде
```

#### 3. Проверить ZooKeeper

```bash
# На любой ноде ZooKeeper
docker exec -it zookeeper-01 zkServer.sh status

# Должно показать "Mode: follower" или "Mode: leader"
```

#### 4. Проверить HAProxy

```bash
# Открыть в браузере
http://<VM-7-IP>:8404

# Должна открыться страница статистики HAProxy
# Все backend серверы должны быть зелеными
```

#### 5. Тестовый запрос через HAProxy

```bash
# ETL endpoint
curl "http://<VM-7-IP>:8080/?query=SELECT version()"

# Analytics endpoint
curl "http://<VM-7-IP>:8081/?query=SELECT version()"

# Должно вернуть версию ClickHouse
```

---

## Управление пользователями и RBAC

### Концепция

В кластере используется **SQL-based RBAC** (Role-Based Access Control) вместо XML конфигурации пользователей.

**Преимущества**:
- Динамическое управление пользователями без перезапуска
- Гранулярные права на уровне таблиц/столбцов/строк
- Репликация прав через ZooKeeper (применяются на всех нодах)

### Начальная настройка

**Пользователи в users.xml** (только для bootstrap):

| Пользователь | Пароль | Профиль | Права |
|--------------|--------|---------|-------|
| `default` | нет | default | localhost only, для внутренних нужд |
| `admin` | admin_super_secure_2024 | admin_profile | Полные права + управление пользователями |

⚠️ **ВАЖНО**: Изменить пароль `admin` сразу после развертывания!

### Создание пользователей через RBAC

#### 1. Подключиться как admin

```bash
clickhouse-client -h <HAProxy-IP> --port 9090 --user admin --password admin_super_secure_2024
```

#### 2. Создать роли

**Роль для ETL (запись)**:
```sql
CREATE ROLE etl_role ON CLUSTER dwh_cluster;

-- Права на создание таблиц
GRANT CREATE TABLE ON *.* TO etl_role;

-- Права на INSERT
GRANT INSERT ON *.* TO etl_role;

-- Права на SELECT (для проверки данных)
GRANT SELECT ON *.* TO etl_role;

-- Права на системные таблицы
GRANT SELECT ON system.* TO etl_role;
```

**Роль для аналитики (чтение)**:
```sql
CREATE ROLE analytics_role ON CLUSTER dwh_cluster;

-- Только SELECT
GRANT SELECT ON *.* TO analytics_role;

-- Системные таблицы
GRANT SELECT ON system.* TO analytics_role;
```

**Роль для отчетов (чтение + тяжелые запросы)**:
```sql
CREATE ROLE reports_role ON CLUSTER dwh_cluster;

-- SELECT с возможностью создавать временные таблицы
GRANT SELECT ON *.* TO reports_role;
GRANT CREATE TEMPORARY TABLE ON *.* TO reports_role;

-- Системные таблицы
GRANT SELECT ON system.* TO reports_role;
```

#### 3. Создать пользователей

**ETL пользователь**:
```sql
CREATE USER etl_user ON CLUSTER dwh_cluster
IDENTIFIED WITH sha256_password BY 'secure_etl_password_2024'
SETTINGS PROFILE 'default';

GRANT etl_role TO etl_user ON CLUSTER dwh_cluster;
```

**Analytics пользователь**:
```sql
CREATE USER analytics_user ON CLUSTER dwh_cluster
IDENTIFIED WITH sha256_password BY 'secure_analytics_password_2024'
SETTINGS PROFILE 'default',
         readonly = 1,
         max_execution_time = 300,
         max_memory_usage = 10000000000;

GRANT analytics_role TO analytics_user ON CLUSTER dwh_cluster;
```

**Reports пользователь**:
```sql
CREATE USER reports_user ON CLUSTER dwh_cluster
IDENTIFIED WITH sha256_password BY 'secure_reports_password_2024'
SETTINGS PROFILE 'default',
         readonly = 1,
         max_execution_time = 1800,
         max_memory_usage = 30000000000,
         max_threads = 24;

GRANT reports_role TO reports_user ON CLUSTER dwh_cluster;
```

#### 4. Проверить пользователей

```sql
-- Список пользователей
SELECT name, auth_type, host_ip, default_roles_list
FROM system.users;

-- Список ролей
SELECT name, granted_role_name
FROM system.role_grants;

-- Права роли
SHOW GRANTS FOR etl_role;
```

### Профили настройки (Settings Profiles)

Для управления лимитами создать профили через SQL:

```sql
-- Профиль для ETL
CREATE SETTINGS PROFILE etl_settings ON CLUSTER dwh_cluster
SETTINGS
    max_memory_usage = 50000000000,           -- 50 GB
    max_execution_time = 3600,                -- 1 час
    max_insert_threads = 16,
    async_insert = 1,
    async_insert_threads = 8,
    max_threads = 32,
    priority = 1;

-- Профиль для Analytics
CREATE SETTINGS PROFILE analytics_settings ON CLUSTER dwh_cluster
SETTINGS
    max_memory_usage = 10000000000,           -- 10 GB
    max_execution_time = 300,                 -- 5 минут
    max_threads = 16,
    readonly = 1,
    priority = 3;

-- Профиль для Reports
CREATE SETTINGS PROFILE reports_settings ON CLUSTER dwh_cluster
SETTINGS
    max_memory_usage = 30000000000,           -- 30 GB
    max_execution_time = 1800,                -- 30 минут
    max_threads = 24,
    max_bytes_in_join = 10000000000,
    readonly = 1,
    priority = 5;
```

Применить профили к пользователям:
```sql
ALTER USER etl_user ON CLUSTER dwh_cluster
SETTINGS PROFILE 'etl_settings';

ALTER USER analytics_user ON CLUSTER dwh_cluster
SETTINGS PROFILE 'analytics_settings';

ALTER USER reports_user ON CLUSTER dwh_cluster
SETTINGS PROFILE 'reports_settings';
```

### Квоты (Quotas)

Ограничение нагрузки на уровне пользователей:

```sql
-- Квота для Analytics (много легких запросов)
CREATE QUOTA analytics_quota ON CLUSTER dwh_cluster
FOR INTERVAL 1 hour MAX queries = 10000,
                         errors = 100,
                         execution_time = 36000;  -- 10 часов суммарно

ALTER USER analytics_user ON CLUSTER dwh_cluster
QUOTA 'analytics_quota';

-- Квота для Reports (мало тяжелых запросов)
CREATE QUOTA reports_quota ON CLUSTER dwh_cluster
FOR INTERVAL 1 hour MAX queries = 100,
                         errors = 10,
FOR INTERVAL 1 day MAX queries = 500,
                        errors = 50;

ALTER USER reports_user ON CLUSTER dwh_cluster
QUOTA 'reports_quota';
```

### Row-level Security (RLS)

Ограничение доступа к строкам (например, по тенантам):

```sql
-- Создать политику: пользователь видит только свои данные
CREATE ROW POLICY tenant_isolation ON events
FOR SELECT USING tenant_id = currentUser() TO analytics_user;

-- Применяется автоматически при SELECT
```

---

## Мониторинг

### Grafana Dashboards

После развертывания импортировать готовые дашборды:

1. Открыть Grafana: `http://<VM-7-IP>:3000`
2. Login: `admin` / `admin123`
3. Импортировать дашборды:
   - ClickHouse Overview: ID `14192`
   - ClickHouse Query Analysis: ID `14999`
   - HAProxy: ID `12693`

### Ключевые метрики для мониторинга

#### ClickHouse Metrics

**Производительность**:
- `ClickHouseMetrics_Query` - текущее количество запросов
- `ClickHouseProfileEvents_Query` - всего запросов (счетчик)
- `ClickHouseProfileEvents_InsertedRows` - вставлено строк
- `ClickHouseProfileEvents_SelectQuery` - SELECT запросов

**Ресурсы**:
- `ClickHouseMetrics_MemoryTracking` - использование памяти
- `ClickHouseMetrics_BackgroundPoolTask` - активных background задач
- `ClickHouseMetrics_BackgroundMergesAndMutationsPoolTask` - активных merge операций

**Репликация**:
- `ClickHouseMetrics_ReplicatedFetch` - копирование частей с других реплик
- `ClickHouseMetrics_ReplicatedSend` - отправка частей на другие реплики
- `ClickHouseMetrics_ReplicationQueue` - размер очереди репликации

**Ошибки**:
- `ClickHouseProfileEvents_FailedQuery` - проваленных запросов
- `ClickHouseProfileEvents_FailedInsertQuery` - проваленных INSERT
- `ClickHouseProfileEvents_FailedSelectQuery` - проваленных SELECT

#### HAProxy Metrics

- Backend status (up/down)
- Requests per second
- Response time (percentiles)
- Error rate
- Active connections

#### ZooKeeper Metrics

- Outstanding requests
- Watch count
- Latency (avg/max)
- Leader election count

### Alerting Rules

**Prometheus alerts** (пример):

```yaml
# /opt/prometheus/config/alerts.yml
groups:
  - name: clickhouse
    interval: 30s
    rules:
      - alert: ClickHouseDown
        expr: up{job="clickhouse"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ClickHouse node {{ $labels.instance }} is down"

      - alert: ClickHouseHighMemoryUsage
        expr: ClickHouseMetrics_MemoryTracking > 100000000000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ClickHouse {{ $labels.instance }} high memory usage"

      - alert: ClickHouseReplicationLag
        expr: ClickHouseMetrics_ReplicationQueue > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Replication lag on {{ $labels.instance }}"

      - alert: ClickHouseFailedQueries
        expr: rate(ClickHouseProfileEvents_FailedQuery[5m]) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High failed query rate on {{ $labels.instance }}"
```

### Логирование

**ClickHouse logs**:
- Location: `/var/log/clickhouse-server/`
- `clickhouse-server.log` - основной лог
- `clickhouse-server.err.log` - только ошибки
- Rotation: 10 файлов по 1 GB

**Query log**:
```sql
-- Медленные запросы (>10 сек)
SELECT
    query_start_time,
    query_duration_ms / 1000 as duration_sec,
    user,
    query,
    read_rows,
    read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000
ORDER BY query_start_time DESC
LIMIT 100;

-- Проваленные запросы
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

## Производительность

### Оценка пропускной способности

**На основе конфигурации Варианта 3**:

#### INSERT (через порт 8080 → Node-01)
- **Простые таблицы**: 2-5M строк/сек
- **Сложные таблицы** (много индексов, материализованные столбцы): 500K-2M строк/сек
- **Batch size**: Рекомендуется 1M-10M строк за запрос
- **Async insert**: Автоматический батчинг до 100 MB

#### SELECT (через порт 8081 → все ноды)
- **Простые агрегации** (COUNT, SUM по индексу): <100ms
- **Сложные агрегации** (GROUP BY по 10+ колонкам): 1-10 сек
- **Full scan** (без индексов): ~10B строк/сек на ноду
- **Параллельные запросы**: до 300-500 одновременно

#### JOIN (через порт 8082 → Node-02/03)
- **Small JOIN** (<1M строк): <1 сек
- **Medium JOIN** (1M-100M строк): 1-10 сек
- **Large JOIN** (100M-1B строк): 10-60 сек
- **Huge JOIN** (>1B строк): 1-10 минут

### Оптимизация таблиц

**Рекомендуемые движки**:

```sql
-- Для реплицируемых таблиц
CREATE TABLE events ON CLUSTER dwh_cluster (
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    -- ...
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_time)
SETTINGS
    index_granularity = 8192,
    min_bytes_for_wide_part = 10485760;  -- 10 MB
```

**Best practices**:
- **PARTITION BY**: По месяцам для больших таблиц, по дням для очень больших
- **ORDER BY**: Часто фильтруемые колонки в начале
- **Index granularity**: 8192 по умолчанию (меньше для малых строк, больше для широких)
- **Compression**: ZSTD level 3 (баланс скорости и сжатия)

### Партиционирование

**Стратегия для разных размеров таблиц**:

| Размер таблицы | PARTITION BY | Причина |
|----------------|--------------|---------|
| <100M строк | `toYear(date)` | Не нужно дробить |
| 100M-1B строк | `toYYYYMM(date)` | Баланс между кол-вом партиций и размером |
| >1B строк | `toMonday(date)` или `toYYYYMM(date)` | Быстрое удаление старых данных |

**Пример для 2B таблицы**:
```sql
CREATE TABLE big_events ON CLUSTER dwh_cluster (
    event_date Date,
    -- ...
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/big_events', '{replica}')
PARTITION BY toYYYYMM(event_date)  -- ~24 партиции за 2 года
ORDER BY (event_date, user_id);
```

### Индексы

**Skip indexes** для ускорения фильтрации:

```sql
-- Индекс по строковому полю
ALTER TABLE events ON CLUSTER dwh_cluster
ADD INDEX idx_event_type event_type TYPE set(100) GRANULARITY 4;

-- Индекс по диапазону
ALTER TABLE events ON CLUSTER dwh_cluster
ADD INDEX idx_user_id user_id TYPE minmax GRANULARITY 1;

-- Bloom filter для поиска по строкам
ALTER TABLE events ON CLUSTER dwh_cluster
ADD INDEX idx_url url TYPE bloom_filter GRANULARITY 4;
```

---

## Резервное копирование

### Стратегия backup

#### 1. ClickHouse BACKUP (рекомендуется)

**Полный бэкап кластера**:
```sql
-- На любой ноде
BACKUP TABLE events, users, transactions
TO Disk('backups', 'backup_2024_10_01.zip');

-- Или весь кластер
BACKUP DATABASE dwh TO Disk('backups', 'full_backup_2024_10_01.zip');
```

**Восстановление**:
```sql
RESTORE DATABASE dwh FROM Disk('backups', 'full_backup_2024_10_01.zip');
```

**Автоматизация** (cron на VM-7):
```bash
#!/bin/bash
# /opt/scripts/clickhouse_backup.sh

DATE=$(date +%Y_%m_%d)
BACKUP_NAME="backup_${DATE}.zip"

clickhouse-client -h clickhouse-01 --port 9000 --user admin --password admin_super_secure_2024 --query \
"BACKUP DATABASE dwh TO Disk('backups', '${BACKUP_NAME}')"

# Удалить бэкапы старше 7 дней
find /backups -name "backup_*.zip" -mtime +7 -delete
```

Добавить в crontab:
```
0 2 * * * /opt/scripts/clickhouse_backup.sh
```

#### 2. ZooKeeper snapshot

**Автоматически создается ZooKeeper**, но можно форсировать:
```bash
docker exec zookeeper-01 zkServer.sh snapshot
```

Бэкапы хранятся в `/data/version-2/` внутри контейнера.

#### 3. Volumes backup

**Остановить контейнер и скопировать volume**:
```bash
# На VM-1
docker stop clickhouse-01
docker run --rm -v clickhouse-01-data:/data -v /backups:/backup \
  ubuntu tar czf /backup/clickhouse-01-volume-2024-10-01.tar.gz /data
docker start clickhouse-01
```

### Disaster Recovery

**Сценарий 1: Потеря одной ноды ClickHouse**
1. Кластер продолжает работать (2 реплики остались)
2. Развернуть новую VM
3. Запустить ClickHouse с той же конфигурацией
4. Данные автоматически реплицируются с других нод

**Сценарий 2: Потеря всех нод ClickHouse**
1. Развернуть 3 новые VM
2. Восстановить ZooKeeper (если он тоже потерян)
3. На одной ноде восстановить из бэкапа:
   ```sql
   RESTORE DATABASE dwh FROM Disk('backups', 'latest_backup.zip');
   ```
4. Запустить остальные ноды - данные реплицируются

**Сценарий 3: Потеря ZooKeeper кворума**
1. Если потеряны 2+ ноды ZK → кластер не работает
2. Восстановить ноды ZK из snapshot
3. Перезапустить ClickHouse ноды для переподключения

---

## Troubleshooting

### Проблемы с репликацией

**Симптом**: `system.replication_queue` растет

```sql
-- Проверить очередь репликации
SELECT
    database,
    table,
    replica_name,
    num_tries,
    last_exception
FROM system.replication_queue
WHERE num_tries > 10;

-- Принудительно синхронизировать реплику
SYSTEM SYNC REPLICA events;

-- Очистить сломанную реплику (крайняя мера)
SYSTEM DROP REPLICA 'replica_02' FROM TABLE events;
```

### Проблемы с ZooKeeper

**Симптом**: "Coordination::Exception: Session expired"

```bash
# Проверить статус ZK
docker exec zookeeper-01 zkServer.sh status

# Проверить подключения
docker exec zookeeper-01 zkCli.sh -server localhost:2181 ls /clickhouse

# Увеличить session timeout в config.xml
<zookeeper>
    <session_timeout_ms>60000</session_timeout_ms>  <!-- было 30000 -->
</zookeeper>
```

### Медленные запросы

```sql
-- Найти медленные запросы
SELECT
    query_start_time,
    query_duration_ms / 1000 as duration_sec,
    user,
    substring(query, 1, 100) as query_short,
    read_rows,
    read_bytes,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- Включить подробное логирование
SET send_logs_level = 'trace';
```

### Переполнение диска

```sql
-- Проверить размер таблиц
SELECT
    database,
    table,
    formatReadableSize(sum(bytes)) as size,
    sum(rows) as rows
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes) DESC;

-- Удалить старые партиции
ALTER TABLE events DROP PARTITION '202301';

-- Оптимизировать таблицу (осторожно, нагружает систему)
OPTIMIZE TABLE events FINAL;
```

### HAProxy backend down

```bash
# Проверить статус
curl http://<VM-7-IP>:8404

# Проверить health check
curl http://clickhouse-01:8123/ping

# Проверить логи HAProxy
docker logs haproxy

# Вручную пометить сервер как UP
echo "set server clickhouse_etl_http/clickhouse-01 state ready" | \
  docker exec -i haproxy socat stdio /var/run/haproxy.sock
```

### Out of Memory

```sql
-- Проверить использование памяти
SELECT
    user,
    sum(memory_usage) as total_memory,
    count() as queries
FROM system.processes
GROUP BY user;

-- Убить тяжелый запрос
KILL QUERY WHERE query_id = 'xxx';

-- Увеличить лимит памяти (временно)
SET max_memory_usage = 100000000000;  -- 100 GB
```

---

## Сетевая безопасность

### Рекомендации

1. **Изолировать внутреннюю сеть**:
   - ClickHouse ноды, ZooKeeper - только внутренняя VLAN
   - HAProxy - единственная точка входа извне

2. **Ограничить доступ по IP**:
```sql
-- Разрешить подключение только с определенных IP
CREATE USER etl_user
IDENTIFIED WITH sha256_password BY 'password'
HOST IP '10.0.1.0/24', IP '10.0.2.0/24';
```

3. **SSL/TLS** (опционально):
   - Настроить SSL сертификаты для ClickHouse
   - Настроить HTTPS для HAProxy

4. **VPN/Bastion**:
   - Доступ к VM только через VPN или bastion host
   - SSH ключи вместо паролей

---

## Масштабирование

### Вертикальное (scale up)

**Увеличение ресурсов существующих VM**:
- CPU: 32 → 64 cores
- RAM: 128 → 256 GB
- Disk: 2 TB → 4-8 TB

### Горизонтальное (scale out)

**Добавление новых шардов** (когда данных очень много):

1. Создать новые VM (VM-8, VM-9, VM-10)
2. Настроить как новый шард:
```xml
<remote_servers>
    <dwh_cluster>
        <!-- Существующий шард -->
        <shard>
            <internal_replication>true</internal_replication>
            <replica><host>clickhouse-01</host></replica>
            <replica><host>clickhouse-02</host></replica>
            <replica><host>clickhouse-03</host></replica>
        </shard>

        <!-- Новый шард -->
        <shard>
            <internal_replication>true</internal_replication>
            <replica><host>clickhouse-04</host></replica>
            <replica><host>clickhouse-05</host></replica>
            <replica><host>clickhouse-06</host></replica>
        </shard>
    </dwh_cluster>
</remote_servers>
```

3. Пересоздать таблицы с `Distributed` движком:
```sql
CREATE TABLE events_distributed ON CLUSTER dwh_cluster AS events
ENGINE = Distributed(dwh_cluster, default, events, rand());
```

---

## Контакты и поддержка

**Документация ClickHouse**: https://clickhouse.com/docs
**Community Slack**: https://clickhouse.com/slack
**GitHub Issues**: https://github.com/ClickHouse/ClickHouse/issues

---

## Changelog

| Версия | Дата | Изменения |
|--------|------|-----------|
| 1.0 | 2024-10-01 | Начальная версия документации |

