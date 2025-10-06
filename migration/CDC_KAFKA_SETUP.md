# CDC Pipeline: MS SQL → Kafka → ClickHouse

## Обзор

Настройка Change Data Capture (CDC) для репликации данных из MS SQL Server в ClickHouse через Kafka в реальном времени.

```
MS SQL Server (rpmu.person.person)
        │
        │ CDC (Change Data Capture)
        ▼
  SQL Server Agent / Debezium
        │
        │ JSON/Avro messages
        ▼
    Apache Kafka
        │
        │ Topic: rpmu.person.person
        ▼
  ClickHouse Kafka Engine
        │
        │ Materialized View
        ▼
  ClickHouse Table (rpmu.person)
```

---

## Вариант 1: Debezium Connector (Рекомендуется)

### Преимущества:
- ✅ Минимальная нагрузка на MS SQL
- ✅ Захват всех изменений (INSERT, UPDATE, DELETE)
- ✅ Exactly-once delivery
- ✅ Автоматическая обработка схемы

### Шаг 1: Включить CDC в MS SQL Server

```sql
-- 1. Включить CDC на базе данных
USE rpmu;
GO

EXEC sys.sp_cdc_enable_db;
GO

-- 2. Включить CDC на таблице person
EXEC sys.sp_cdc_enable_table
    @source_schema = N'person',
    @source_name = N'person',
    @role_name = NULL,
    @supports_net_changes = 1;
GO

-- 3. Проверить статус CDC
SELECT name, is_cdc_enabled
FROM sys.databases
WHERE name = 'rpmu';

SELECT name, is_tracked_by_cdc
FROM sys.tables
WHERE schema_id = SCHEMA_ID('person');
```

### Шаг 2: Установить Debezium

**Docker Compose для Debezium + Kafka** (создать на отдельной VM или на VM-4):

```yaml
version: '3.8'

services:
  zookeeper-kafka:
    image: confluentinc/cp-zookeeper:7.5.0
    container_name: zookeeper-kafka
    environment:
      ZOOKEEPER_CLIENT_PORT: 2182
      ZOOKEEPER_TICK_TIME: 2000
    ports:
      - "2182:2182"
    volumes:
      - /data/zookeeper-kafka:/var/lib/zookeeper/data

  kafka:
    image: confluentinc/cp-kafka:7.5.0
    container_name: kafka
    depends_on:
      - zookeeper-kafka
    ports:
      - "9092:9092"
      - "9093:9093"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper-kafka:2182
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://192.168.9.113:9092,PLAINTEXT_INTERNAL://kafka:9093
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_INTERNAL:PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
    volumes:
      - /data/kafka:/var/lib/kafka/data

  kafka-connect:
    image: debezium/connect:2.5
    container_name: kafka-connect
    depends_on:
      - kafka
    ports:
      - "8083:8083"
    environment:
      BOOTSTRAP_SERVERS: kafka:9093
      GROUP_ID: debezium-cluster
      CONFIG_STORAGE_TOPIC: debezium_configs
      OFFSET_STORAGE_TOPIC: debezium_offsets
      STATUS_STORAGE_TOPIC: debezium_status
      CONFIG_STORAGE_REPLICATION_FACTOR: 1
      OFFSET_STORAGE_REPLICATION_FACTOR: 1
      STATUS_STORAGE_REPLICATION_FACTOR: 1

  schema-registry:
    image: confluentinc/cp-schema-registry:7.5.0
    container_name: schema-registry
    depends_on:
      - kafka
    ports:
      - "8081:8081"
    environment:
      SCHEMA_REGISTRY_HOST_NAME: schema-registry
      SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS: kafka:9093
```

### Шаг 3: Настроить Debezium Connector для MS SQL

```bash
curl -X POST http://192.168.9.113:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
  "name": "rpmu-person-connector",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "database.hostname": "<MS_SQL_SERVER_IP>",
    "database.port": "1433",
    "database.user": "debezium_user",
    "database.password": "STRONG_PASSWORD",
    "database.dbname": "rpmu",
    "database.server.name": "rpmu_server",
    "table.include.list": "person.person",
    "database.history.kafka.bootstrap.servers": "kafka:9093",
    "database.history.kafka.topic": "schema-changes.rpmu",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "true"
  }
}'
```

**Создать пользователя в MS SQL для Debezium**:

```sql
-- В MS SQL Server
USE rpmu;
GO

CREATE LOGIN debezium_user WITH PASSWORD = 'STRONG_PASSWORD';
CREATE USER debezium_user FOR LOGIN debezium_user;

-- Дать права на чтение CDC
EXEC sys.sp_addrolemember @rolename = 'db_datareader', @membername = 'debezium_user';
EXEC sys.sp_cdc_add_job @job_type = N'capture';
```

### Шаг 4: Создать Kafka Engine в ClickHouse

На **каждой ноде ClickHouse (VM-1, VM-2, VM-3)** создать Kafka таблицу:

```sql
-- Kafka таблица для приема сообщений
CREATE TABLE rpmu.person_kafka ON CLUSTER dwh_cluster
(
    `id` String,
    `iin` String,
    `last_name` String,
    `first_name` String,
    `patronymic_name` String,
    `birth_date` String,
    `death_date` String,
    `gender_id` String,
    `nationality_id` String,
    `citizenship_id` String,
    `is_del` UInt8,
    `parent_id` String,
    `rpn_id` String,
    `create_date` String,
    `created_by` String,
    `update_date` String,
    `updated_by` String,
    `version` Int32,
    `is_gbdfl` UInt8,
    `departure_date` String,
    `person_attribute_id` String,
    `_operation` String  -- INSERT, UPDATE, DELETE
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = '192.168.9.113:9092',
    kafka_topic_list = 'rpmu_server.person.person',
    kafka_group_name = 'clickhouse_person_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3,
    kafka_skip_broken_messages = 10;
```

### Шаг 5: Создать Materialized View для трансформации

```sql
-- Materialized View для INSERT/UPDATE
CREATE MATERIALIZED VIEW rpmu.person_kafka_mv ON CLUSTER dwh_cluster
TO rpmu.person
AS
SELECT
    toUUID(id) AS id,
    iin,
    last_name,
    first_name,
    patronymic_name,
    parseDateTimeBestEffort(birth_date) AS birth_date,
    parseDateTimeBestEffortOrNull(death_date) AS death_date,
    toUUID(gender_id) AS gender_id,
    toUUID(nationality_id) AS nationality_id,
    toUUID(citizenship_id) AS citizenship_id,
    is_del,
    toUUID(parent_id) AS parent_id,
    rpn_id,
    parseDateTimeBestEffort(create_date) AS create_date,
    toUUID(created_by) AS created_by,
    parseDateTimeBestEffortOrNull(update_date) AS update_date,
    toUUIDOrNull(updated_by) AS updated_by,
    version,
    is_gbdfl,
    parseDateTimeBestEffortOrNull(departure_date) AS departure_date,
    toUUIDOrNull(person_attribute_id) AS person_attribute_id
FROM rpmu.person_kafka
WHERE _operation IN ('c', 'r', 'u');  -- c=create, r=read, u=update

-- Отдельная MV для DELETE (опционально)
CREATE MATERIALIZED VIEW rpmu.person_kafka_delete_mv ON CLUSTER dwh_cluster
TO rpmu.person
AS
SELECT
    toUUID(id) AS id,
    iin,
    last_name,
    first_name,
    patronymic_name,
    parseDateTimeBestEffort(birth_date) AS birth_date,
    parseDateTimeBestEffortOrNull(death_date) AS death_date,
    toUUID(gender_id) AS gender_id,
    toUUID(nationality_id) AS nationality_id,
    toUUID(citizenship_id) AS citizenship_id,
    1 AS is_del,  -- Помечаем как удаленное
    toUUID(parent_id) AS parent_id,
    rpn_id,
    parseDateTimeBestEffort(create_date) AS create_date,
    toUUID(created_by) AS created_by,
    now() AS update_date,
    toUUIDOrNull(updated_by) AS updated_by,
    version + 1 AS version,
    is_gbdfl,
    parseDateTimeBestEffortOrNull(departure_date) AS departure_date,
    toUUIDOrNull(person_attribute_id) AS person_attribute_id
FROM rpmu.person_kafka
WHERE _operation = 'd';  -- d=delete
```

---

## Вариант 2: Упрощенный (без Debezium)

Если Debezium сложен, можно использовать простой скрипт на Python.

### Python скрипт для CDC

```python
#!/usr/bin/env python3
import pyodbc
import json
from kafka import KafkaProducer
import time

# Подключение к MS SQL
mssql_conn = pyodbc.connect(
    'DRIVER={ODBC Driver 17 for SQL Server};'
    'SERVER=<MS_SQL_IP>;'
    'DATABASE=rpmu;'
    'UID=cdc_user;'
    'PWD=password'
)

# Kafka producer
producer = KafkaProducer(
    bootstrap_servers=['192.168.9.113:9092'],
    value_serializer=lambda v: json.dumps(v).encode('utf-8')
)

# Запрос изменений из CDC
query = """
SELECT
    __$operation as operation,  -- 2=INSERT, 4=UPDATE, 1=DELETE
    id, iin, last_name, first_name, patronymic_name,
    birth_date, death_date, gender_id, nationality_id,
    citizenship_id, is_del, parent_id, rpn_id,
    create_date, created_by, update_date, updated_by,
    version, is_gbdfl, departure_date, person_attribute_id
FROM cdc.person_CT
WHERE __$start_lsn > ?
ORDER BY __$start_lsn
"""

last_lsn = 0  # Начальная позиция

while True:
    cursor = mssql_conn.cursor()
    cursor.execute(query, (last_lsn,))

    for row in cursor:
        message = {
            '_operation': 'c' if row.operation == 2 else ('u' if row.operation == 4 else 'd'),
            'id': str(row.id),
            'iin': row.iin,
            'last_name': row.last_name,
            # ... остальные поля
        }

        producer.send('rpmu.person.person', value=message)
        last_lsn = row.__$start_lsn

    producer.flush()
    time.sleep(5)  # Проверять изменения каждые 5 секунд
```

---

## Мониторинг CDC Pipeline

### 1. Kafka топики

```bash
# Список топиков
docker exec kafka kafka-topics --list --bootstrap-server localhost:9093

# Проверить сообщения в топике
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9093 \
  --topic rpmu_server.person.person \
  --from-beginning \
  --max-messages 10
```

### 2. ClickHouse Kafka Engine

```sql
-- Проверить статус потребления
SELECT * FROM system.kafka_consumers;

-- Ошибки Kafka
SELECT * FROM system.text_log
WHERE logger_name LIKE '%Kafka%' AND level = 'Error'
ORDER BY event_time DESC
LIMIT 100;

-- Количество обработанных сообщений
SELECT
    count() as total_messages,
    max(create_date) as last_message_time
FROM rpmu.person;
```

### 3. Debezium Connector

```bash
# Статус connector
curl http://192.168.9.113:8083/connectors/rpmu-person-connector/status

# Логи
docker logs kafka-connect -f
```

---

## Производительность CDC

### Ожидаемая пропускная способность:

| Метрика | Значение |
|---------|----------|
| Вставка (INSERT) | 50K-100K строк/сек |
| Обновление (UPDATE) | 30K-50K строк/сек |
| Удаление (DELETE) | 50K строк/сек |
| Задержка (latency) | <1 сек (MS SQL → ClickHouse) |

### Оптимизация:

1. **Батчинг в Kafka**:
   ```sql
   kafka_num_consumers = 6,  -- Больше consumers
   kafka_poll_max_batch_size = 10000
   ```

2. **Партиционирование в Kafka** (по IIN):
   ```java
   // В Debezium connector
   "transforms": "route",
   "transforms.route.type": "org.apache.kafka.connect.transforms.ExtractField$Key",
   "transforms.route.field": "iin"
   ```

3. **Асинхронная вставка в ClickHouse**:
   ```sql
   SET async_insert = 1;
   SET wait_for_async_insert = 0;
   ```

---

## Troubleshooting

### Проблема: Сообщения не появляются в ClickHouse

```sql
-- Проверить Kafka таблицу напрямую
SELECT * FROM rpmu.person_kafka LIMIT 10;

-- Если пусто, проверить Kafka broker
```

### Проблема: Ошибки парсинга UUID

```sql
-- В MV использовать безопасные функции
toUUIDOrZero(id)  -- Вместо toUUID(id)
parseDateTimeBestEffortOrNull(date_field)
```

### Проблема: Дублирование данных

```sql
-- Использовать ReplacingMergeTree вместо ReplicatedMergeTree
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/rpmu/person', '{replica}', version)
ORDER BY (iin, rpn_id, id);

-- Запросы должны делать FINAL
SELECT * FROM rpmu.person FINAL WHERE iin = '...';
```

---

## Следующие шаги

1. ✅ Создать структуру таблицы в ClickHouse
2. ⏳ Включить CDC в MS SQL
3. ⏳ Развернуть Kafka + Debezium
4. ⏳ Настроить Kafka Engine в ClickHouse
5. ⏳ Протестировать репликацию
6. ⏳ Настроить мониторинг

---

## Полезные ссылки

- [ClickHouse Kafka Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/kafka)
- [Debezium SQL Server Connector](https://debezium.io/documentation/reference/stable/connectors/sqlserver.html)
- [MS SQL Server CDC](https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/about-change-data-capture-sql-server)
