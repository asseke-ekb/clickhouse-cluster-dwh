# Миграция MS SQL → ClickHouse: Таблица person

## Обзор

Миграция таблицы `rpmu.person.person` из MS SQL Server в ClickHouse DWH кластер.

**Источник**: MS SQL Server (RPMU database)
**Назначение**: ClickHouse Cluster (3 ноды, 1 шард, 3 реплики)
**Дата миграции**: 2025-10-06

---

## Архитектура ClickHouse кластера

```
HAProxy (192.168.9.113)
    │
    ├─── clickhouse-01 (192.168.9.110) + zookeeper-01
    ├─── clickhouse-02 (192.168.9.111) + zookeeper-02
    └─── clickhouse-03 (192.168.9.112) + zookeeper-03

Репликация: 1 шард, 3 реплики (полная репликация данных)
```

---

## Структура таблицы

### MS SQL → ClickHouse маппинг

| MS SQL тип | MS SQL NULL | ClickHouse тип | Пример поля |
|------------|-------------|----------------|-------------|
| `uniqueidentifier NOT NULL` | ❌ | `UUID` | `id`, `created_by` |
| `uniqueidentifier NULL` | ✅ | `Nullable(UUID)` | `gender_id`, `parent_id` |
| `varchar(255) NULL` | ✅ | `Nullable(String)` | `iin`, `last_name` |
| `datetime NOT NULL` | ❌ | `DateTime64(3)` | `create_date` |
| `datetime NULL` | ✅ | `Nullable(String)` | `birth_date`, `death_date` |
| `bit NULL` | ✅ | `Nullable(UInt8)` | `is_del`, `is_gbdfl` |
| `int NULL` | ✅ | `Nullable(Int32)` | `version` |

### Особенности

- **Даты как String**: `birth_date`, `death_date`, `departure_date` - для совместимости с MS SQL экспортом
- **UUID**: Вставляются как строки `'550e8400-e29b-41d4-a716-446655440000'`
- **DateTime64(3)**: Точность до миллисекунд для `create_date`, `update_date`

---

## Быстрый старт

### 1. Создать таблицу в ClickHouse

```bash
# Подключиться к кластеру
clickhouse-client -h 192.168.9.113 --port 9090 -u admin --password <password>
```

```sql
-- Выполнить скрипт создания
-- (содержимое файла person_final_production.sql)
```

### 2. Проверить создание

```sql
-- Должно вернуть 3 строки (по одной на ноду)
SELECT
    hostName() as node,
    database,
    name,
    engine
FROM cluster('dwh_cluster', system.tables)
WHERE database = 'rpmu' AND name = 'person';
```

### 3. Экспорт данных из MS SQL

```sql
-- В MS SQL Server выполнить:
SELECT
    CONVERT(VARCHAR(36), id) as id,
    CONVERT(VARCHAR(23), create_date, 121) as create_date,
    CONVERT(VARCHAR(36), created_by) as created_by,
    ISNULL(iin, '') as iin,
    ISNULL(last_name, '') as last_name,
    ISNULL(first_name, '') as first_name,
    ISNULL(patronymic_name, '') as patronymic_name,
    ISNULL(CONVERT(VARCHAR(23), birth_date, 121), '') as birth_date,
    ISNULL(CONVERT(VARCHAR(23), death_date, 121), '') as death_date,
    ISNULL(CONVERT(VARCHAR(36), gender_id), '') as gender_id,
    ISNULL(CONVERT(VARCHAR(36), nationality_id), '') as nationality_id,
    ISNULL(CONVERT(VARCHAR(36), citizenship_id), '') as citizenship_id,
    ISNULL(CAST(is_del AS TINYINT), 0) as is_del,
    ISNULL(CONVERT(VARCHAR(36), parent_id), '') as parent_id,
    ISNULL(rpn_id, '') as rpn_id,
    ISNULL(CONVERT(VARCHAR(23), update_date, 121), '') as update_date,
    ISNULL(CONVERT(VARCHAR(36), updated_by), '') as updated_by,
    ISNULL(version, 0) as version,
    ISNULL(CAST(is_gbdfl AS TINYINT), 0) as is_gbdfl,
    ISNULL(CONVERT(VARCHAR(23), departure_date, 121), '') as departure_date,
    ISNULL(CONVERT(VARCHAR(36), person_attribute_id), '') as person_attribute_id
FROM rpmu.person.person
WHERE is_del = 0;
```

Экспортировать в CSV:
```bash
bcp "SELECT ... FROM rpmu.person.person" queryout person_export.csv -c -t, -S <server> -U <user> -P <password>
```

### 4. Импорт в ClickHouse

```bash
# Загрузить CSV
clickhouse-client -h 192.168.9.113 --port 9090 -u admin --password <pass> --query \
"INSERT INTO rpmu.person FORMAT CSVWithNames" < person_export.csv
```

### 5. Проверить репликацию

```sql
-- Данные должны быть на всех 3 нодах
SELECT
    hostName() as node,
    count() as rows
FROM cluster('dwh_cluster', rpmu.person)
GROUP BY hostName();
```

---

## Pentaho Data Integration (PDI)

### Table Output настройки

1. **Connection**: ClickHouse JDBC
   - JDBC URL: `jdbc:clickhouse://192.168.9.113:8080/rpmu`
   - Driver: `com.clickhouse.jdbc.ClickHouseDriver`

2. **Target schema**: `rpmu`

3. **Target table**: `person`

4. **Specify database fields**: `YES`

5. **Field mapping**:

| Stream field (Pentaho) | Table field (ClickHouse) | Type |
|------------------------|--------------------------|------|
| MS_SQL_ID | id | UUID |
| MS_SQL_IIN | iin | String |
| MS_SQL_LAST_NAME | last_name | String |
| MS_SQL_FIRST_NAME | first_name | String |
| ... | ... | ... |

### Пример трансформации (PDI)

```
MS SQL Input
    │
    ├─ Select Values (конвертация типов)
    │   - GUID → String (36 символов)
    │   - DateTime → String (23 символа)
    │   - bit → Integer (0/1)
    │
    └─ Table Output (ClickHouse)
        - Batch: 10000 строк
        - Commit: 10000 строк
```

---

## CDC Pipeline (Real-time репликация)

Для настройки CDC через Kafka см. [CDC_KAFKA_SETUP.md](CDC_KAFKA_SETUP.md)

**Архитектура**:
```
MS SQL (CDC) → Debezium → Kafka → ClickHouse Kafka Engine → person
```

**Пропускная способность**:
- INSERT: 50K-100K строк/сек
- UPDATE: 30K-50K строк/сек
- Latency: <1 сек

---

## Примеры запросов

### 1. Поиск по ИИН

```sql
SELECT * FROM rpmu.person
WHERE iin = '900101300123';
```

### 2. Поиск по ФИО

```sql
SELECT * FROM rpmu.person
WHERE last_name = 'Иванов'
  AND first_name = 'Иван'
  AND patronymic_name = 'Иванович';
```

### 3. Активные пациенты

```sql
SELECT
    id,
    iin,
    last_name,
    first_name,
    patronymic_name,
    birth_date
FROM rpmu.person
WHERE (is_del = 0 OR is_del IS NULL)
  AND death_date IS NULL
LIMIT 100;
```

### 4. JOIN со справочниками

```sql
SELECT
    p.iin,
    p.last_name,
    p.first_name,
    p.patronymic_name,
    g.name as gender,
    n.name as nationality,
    c.name as citizenship
FROM rpmu.person p
LEFT JOIN rpmu.d_gender g ON p.gender_id = g.id
LEFT JOIN rpmu.d_nationality n ON p.nationality_id = n.id
LEFT JOIN rpmu.d_citizenship c ON p.citizenship_id = c.id
WHERE p.is_del = 0
LIMIT 100;
```

### 5. Статистика по годам рождения

```sql
SELECT
    substring(birth_date, 1, 4) as birth_year,
    count() as total,
    countIf(is_del = 0) as active,
    countIf(death_date IS NOT NULL) as deceased
FROM rpmu.person
WHERE birth_date IS NOT NULL
GROUP BY birth_year
ORDER BY birth_year DESC;
```

---

## Производительность

### Ожидаемые показатели

| Операция | Производительность | Примечания |
|----------|-------------------|------------|
| INSERT (batch) | 100K-500K строк/сек | Через HAProxy ETL endpoint (8080) |
| SELECT по id | <10ms | Прямой поиск по PRIMARY KEY |
| SELECT по iin | <50ms | Через bloom filter индекс |
| SELECT по ФИО | <100ms | Через bloom filter индекс |
| JOIN с справочниками | <200ms | Для небольших справочников (<1M) |
| Full scan (count) | ~1M строк/сек | Без фильтров |

### Оптимизация

1. **Batch INSERT**: Вставлять пакетами по 10K-100K строк
2. **Async INSERT**: Использовать `SET async_insert = 1` для высокой нагрузки
3. **Параллельность**: Использовать все 3 ноды через HAProxy
4. **Индексы**: Bloom filter индексы для iin, ФИО, rpn_id

---

## Мониторинг

### Размер таблицы

```sql
SELECT
    formatReadableSize(sum(bytes_on_disk)) as size_on_disk,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) as compression_ratio
FROM system.parts
WHERE database = 'rpmu' AND table = 'person' AND active;
```

### Количество строк

```sql
SELECT count() as total_rows FROM rpmu.person;
```

### Репликация

```sql
-- Проверить что данные на всех нодах одинаковые
SELECT
    hostName() as node,
    count() as rows
FROM cluster('dwh_cluster', rpmu.person)
GROUP BY hostName();
```

### Медленные запросы

```sql
SELECT
    query_start_time,
    query_duration_ms / 1000 as duration_sec,
    user,
    substring(query, 1, 100) as query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%rpmu.person%'
  AND query_duration_ms > 1000
ORDER BY query_start_time DESC
LIMIT 20;
```

---

## Troubleshooting

### Проблема: METADATA_MISMATCH при создании таблицы

**Ошибка**: `Existing table metadata in ZooKeeper differs in primary key`

**Решение**:
1. Удалить таблицу на каждой ноде отдельно:
   ```sql
   -- На каждой ноде (110, 111, 112)
   DROP TABLE IF EXISTS rpmu.person SYNC;
   ```

2. Очистить ZooKeeper:
   ```bash
   docker exec -it zookeeper-01 zkCli.sh
   deleteall /clickhouse/tables/01/rpmu/person
   quit
   ```

3. Пересоздать таблицу через `ON CLUSTER`

### Проблема: Данные не реплицируются

**Диагностика**:
```sql
-- Проверить очередь репликации
SELECT * FROM system.replication_queue;

-- Проверить статус реплик
SELECT * FROM system.replicas
WHERE database = 'rpmu' AND table = 'person';
```

**Решение**:
```sql
-- Принудительная синхронизация
SYSTEM SYNC REPLICA rpmu.person;
```

### Проблема: Медленные INSERT

**Причины**:
- Малый размер batch (вставка по 1 строке)
- Нет async_insert
- Много индексов

**Решение**:
```sql
-- Включить асинхронную вставку
SET async_insert = 1;
SET wait_for_async_insert = 0;

-- Увеличить batch size в Pentaho/приложении
-- Batch: 10000-50000 строк
```

---

## Файлы проекта

```
migration/
├── README.md                           # Этот файл
├── person_final_production.sql         # Финальная конфигурация таблицы
├── person_table_for_mssql_import.sql   # Версия с MATERIALIZED колонками
├── fix_person_metadata_conflict.sql    # Решение проблем с ZooKeeper
├── mssql_to_clickhouse_person.sql      # Первая версия миграции
└── CDC_KAFKA_SETUP.md                  # Настройка CDC pipeline
```

---

## Следующие шаги

1. ✅ Создать таблицу в ClickHouse
2. ⏳ Выполнить начальную загрузку данных из MS SQL
3. ⏳ Настроить CDC для real-time репликации (опционально)
4. ⏳ Настроить мониторинг и алерты
5. ⏳ Оптимизировать индексы по реальным запросам
6. ⏳ Настроить бэкапы

---

## Контакты и поддержка

**Администратор кластера**: DWH Team
**Кластер**: dwh_cluster (192.168.9.110-113)
**HAProxy**: http://192.168.9.113:8404 (stats)
**Grafana**: http://192.168.9.113:3000
**Prometheus**: http://192.168.9.113:9099

---

## Версионирование

| Версия | Дата | Изменения |
|--------|------|-----------|
| 1.0 | 2025-10-06 | Начальная миграция таблицы person |
