-- =====================================================================
-- Таблица person с поддержкой NULL (как в MS SQL)
-- =====================================================================
--
-- Маппинг NULL полей из MS SQL:
-- - NULL в MS SQL → Nullable() в ClickHouse
-- - NOT NULL в MS SQL → обычный тип в ClickHouse
--
-- Поля NOT NULL в MS SQL:
-- - id (PK)
-- - create_date
-- - created_by
--
-- Все остальные поля могут быть NULL
-- =====================================================================

-- Создать базу данных
CREATE DATABASE IF NOT EXISTS rpmu ON CLUSTER dwh_cluster;

-- Основная таблица person с Nullable полями
CREATE TABLE rpmu.person ON CLUSTER dwh_cluster
(
    -- =================================================================
    -- NOT NULL поля (обязательные в MS SQL)
    -- =================================================================

    `id` String,                                -- uniqueidentifier NOT NULL (PK)
    `create_date` String,                       -- datetime NOT NULL
    `created_by` String,                        -- uniqueidentifier NOT NULL

    -- =================================================================
    -- NULLABLE поля (могут быть NULL в MS SQL)
    -- =================================================================

    -- Основные данные (все Nullable в MS SQL)
    `iin` Nullable(String),                     -- varchar(255) NULL
    `last_name` Nullable(String),               -- varchar(255) NULL
    `first_name` Nullable(String),              -- varchar(255) NULL
    `patronymic_name` Nullable(String),         -- varchar(255) NULL

    -- Даты (все Nullable в MS SQL)
    `birth_date` Nullable(String),              -- datetime NULL
    `death_date` Nullable(String),              -- datetime NULL
    `departure_date` Nullable(String),          -- datetime NULL

    -- Справочники (все Nullable в MS SQL)
    `gender_id` Nullable(String),               -- uniqueidentifier NULL
    `nationality_id` Nullable(String),          -- uniqueidentifier NULL
    `citizenship_id` Nullable(String),          -- uniqueidentifier NULL

    -- Флаги (Nullable в MS SQL)
    `is_del` Nullable(UInt8),                   -- bit NULL
    `is_gbdfl` Nullable(UInt8),                 -- bit NULL

    -- Связи (Nullable в MS SQL)
    `parent_id` Nullable(String),               -- uniqueidentifier NULL
    `rpn_id` Nullable(String),                  -- varchar(255) NULL
    `person_attribute_id` Nullable(String),     -- uniqueidentifier NULL

    -- Служебные поля (Nullable в MS SQL)
    `update_date` Nullable(String),             -- datetime NULL
    `updated_by` Nullable(String),              -- uniqueidentifier NULL
    `version` Nullable(Int32),                  -- int NULL

    -- =================================================================
    -- MATERIALIZED колонки для производительности
    -- =================================================================

    -- UUID колонки (для JOIN)
    `id_uuid` UUID MATERIALIZED toUUIDOrZero(id),
    `gender_id_uuid` UUID MATERIALIZED toUUIDOrZero(ifNull(gender_id, '')),
    `nationality_id_uuid` UUID MATERIALIZED toUUIDOrZero(ifNull(nationality_id, '')),
    `citizenship_id_uuid` UUID MATERIALIZED toUUIDOrZero(ifNull(citizenship_id, '')),
    `created_by_uuid` UUID MATERIALIZED toUUIDOrZero(created_by),
    `parent_id_uuid` UUID MATERIALIZED toUUIDOrZero(ifNull(parent_id, '')),

    -- DateTime колонки (для фильтрации)
    `birth_date_dt` Nullable(DateTime) MATERIALIZED parseDateTimeBestEffortOrNull(birth_date),
    `death_date_dt` Nullable(DateTime) MATERIALIZED parseDateTimeBestEffortOrNull(death_date),
    `create_date_dt` DateTime MATERIALIZED parseDateTimeBestEffortOrZero(create_date),
    `update_date_dt` Nullable(DateTime) MATERIALIZED parseDateTimeBestEffortOrNull(update_date),
    `departure_date_dt` Nullable(DateTime) MATERIALIZED parseDateTimeBestEffortOrNull(departure_date),

    -- Вычисляемые колонки для удобства (ФИО полностью)
    `full_name` String MATERIALIZED concat(
        ifNull(last_name, ''), ' ',
        ifNull(first_name, ''), ' ',
        ifNull(patronymic_name, '')
    )
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/person', '{replica}')
PARTITION BY toYYYYMM(ifNull(birth_date_dt, toDateTime(0)))  -- Партиции по дате рождения
ORDER BY (ifNull(iin, ''), ifNull(rpn_id, ''), id)           -- ORDER BY с обработкой NULL
PRIMARY KEY (ifNull(iin, ''), ifNull(rpn_id, ''))            -- PRIMARY KEY
SETTINGS
    index_granularity = 8192;

-- =====================================================================
-- Skip индексы
-- =====================================================================

-- Индекс по ФИО (для поиска по фамилии)
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_fio (last_name, first_name, patronymic_name) TYPE bloom_filter GRANULARITY 4;

-- Индекс по датам
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_dates (birth_date_dt, death_date_dt) TYPE minmax GRANULARITY 1;

-- Индекс для активных записей
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_is_del is_del TYPE set(3) GRANULARITY 4;  -- set(3) = NULL, 0, 1

-- =====================================================================
-- Справочные таблицы
-- =====================================================================

-- Таблица: d_gender
CREATE TABLE rpmu.d_gender ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),
    `name` LowCardinality(String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_gender', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- Таблица: d_nationality
CREATE TABLE rpmu.d_nationality ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),
    `name` LowCardinality(String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_nationality', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- Таблица: d_citizenship
CREATE TABLE rpmu.d_citizenship ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),
    `name` LowCardinality(String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_citizenship', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- =====================================================================
-- SQL для экспорта из MS SQL Server
-- =====================================================================

/*
-- Выполнить в MS SQL Server для экспорта данных:

SELECT
    -- NOT NULL поля
    CONVERT(VARCHAR(36), id) as id,
    CONVERT(VARCHAR(23), create_date, 121) as create_date,
    CONVERT(VARCHAR(36), created_by) as created_by,

    -- NULLABLE поля (конвертируем NULL в пустую строку для CSV)
    ISNULL(iin, '') as iin,
    ISNULL(last_name, '') as last_name,
    ISNULL(first_name, '') as first_name,
    ISNULL(patronymic_name, '') as patronymic_name,

    -- Даты (NULL → пустая строка)
    ISNULL(CONVERT(VARCHAR(23), birth_date, 121), '') as birth_date,
    ISNULL(CONVERT(VARCHAR(23), death_date, 121), '') as death_date,
    ISNULL(CONVERT(VARCHAR(23), departure_date, 121), '') as departure_date,

    -- UUID (NULL → пустая строка)
    ISNULL(CONVERT(VARCHAR(36), gender_id), '') as gender_id,
    ISNULL(CONVERT(VARCHAR(36), nationality_id), '') as nationality_id,
    ISNULL(CONVERT(VARCHAR(36), citizenship_id), '') as citizenship_id,
    ISNULL(CONVERT(VARCHAR(36), parent_id), '') as parent_id,
    ISNULL(CONVERT(VARCHAR(36), person_attribute_id), '') as person_attribute_id,

    -- Флаги (NULL → 0)
    ISNULL(CAST(is_del AS TINYINT), 0) as is_del,
    ISNULL(CAST(is_gbdfl AS TINYINT), 0) as is_gbdfl,

    -- Другие поля
    ISNULL(rpn_id, '') as rpn_id,
    ISNULL(CONVERT(VARCHAR(23), update_date, 121), '') as update_date,
    ISNULL(CONVERT(VARCHAR(36), updated_by), '') as updated_by,
    ISNULL(version, 0) as version

FROM rpmu.person.person
ORDER BY create_date;

-- Экспортировать в CSV:
-- bcp "SELECT ... FROM rpmu.person.person" queryout person_export.csv -c -t, -S <server> -U <user> -P <password>
*/

-- =====================================================================
-- Примеры INSERT
-- =====================================================================

-- Пример 1: Все поля заполнены
INSERT INTO rpmu.person (
    id, create_date, created_by,
    iin, last_name, first_name, patronymic_name,
    birth_date, gender_id, is_del, rpn_id, version
) VALUES (
    '550e8400-e29b-41d4-a716-446655440000',
    '2024-01-01 12:00:00.000',
    '123e4567-e89b-12d3-a456-426614174000',
    '900101300123',
    'Иванов',
    'Иван',
    'Иванович',
    '1990-01-01 00:00:00.000',
    '123e4567-e89b-12d3-a456-426614174001',
    0,
    'RPN001',
    1
);

-- Пример 2: С NULL значениями (как в MS SQL)
INSERT INTO rpmu.person (
    id, create_date, created_by,
    iin, last_name, first_name, patronymic_name,
    birth_date, death_date, gender_id, is_del, version
) VALUES (
    '650e8400-e29b-41d4-a716-446655440001',
    '2024-01-02 14:00:00.000',
    '123e4567-e89b-12d3-a456-426614174000',
    '850505400456',
    'Петров',
    'Петр',
    NULL,                -- patronymic_name = NULL
    '1985-05-05 00:00:00.000',
    '2023-12-31 23:59:59.000',  -- Умер
    NULL,                -- gender_id = NULL (не указан)
    0,
    1
);

-- =====================================================================
-- Проверочные запросы
-- =====================================================================

-- 1. Проверка NULL значений
SELECT
    id,
    iin,
    last_name,
    first_name,
    patronymic_name,     -- может быть NULL
    birth_date,
    death_date,          -- может быть NULL
    gender_id,           -- может быть NULL
    is_del
FROM rpmu.person
LIMIT 10;

-- 2. Подсчет NULL значений по колонкам
SELECT
    count() as total,
    countIf(iin IS NULL) as iin_null,
    countIf(last_name IS NULL) as last_name_null,
    countIf(first_name IS NULL) as first_name_null,
    countIf(patronymic_name IS NULL) as patronymic_null,
    countIf(birth_date IS NULL) as birth_date_null,
    countIf(death_date IS NULL) as death_date_null,
    countIf(gender_id IS NULL) as gender_null,
    countIf(is_del IS NULL) as is_del_null
FROM rpmu.person;

-- 3. Поиск по ФИО с учетом NULL
SELECT *
FROM rpmu.person
WHERE iin = '900101300123'
  AND (patronymic_name IS NULL OR patronymic_name = 'Иванович');

-- 4. Умершие пациенты (death_date NOT NULL)
SELECT
    iin,
    full_name,
    birth_date,
    death_date
FROM rpmu.person
WHERE death_date IS NOT NULL
  AND death_date_dt IS NOT NULL
ORDER BY death_date_dt DESC
LIMIT 100;

-- 5. JOIN со справочниками с учетом NULL
SELECT
    p.iin,
    p.last_name,
    p.first_name,
    ifNull(g.name, 'Не указан') as gender,
    ifNull(n.name, 'Не указана') as nationality,
    ifNull(c.name, 'Не указано') as citizenship
FROM rpmu.person p
LEFT JOIN rpmu.d_gender g ON p.gender_id_uuid = g.id
LEFT JOIN rpmu.d_nationality n ON p.nationality_id_uuid = n.id
LEFT JOIN rpmu.d_citizenship c ON p.citizenship_id_uuid = c.id
WHERE p.is_del = 0 OR p.is_del IS NULL
LIMIT 100;

-- 6. Статистика по заполненности полей
SELECT
    'iin' as field_name,
    count() as total_rows,
    countIf(iin IS NOT NULL) as filled,
    countIf(iin IS NULL) as null_count,
    round(countIf(iin IS NOT NULL) / count() * 100, 2) as fill_percent
FROM rpmu.person
UNION ALL
SELECT 'last_name', count(), countIf(last_name IS NOT NULL), countIf(last_name IS NULL), round(countIf(last_name IS NOT NULL) / count() * 100, 2) FROM rpmu.person
UNION ALL
SELECT 'first_name', count(), countIf(first_name IS NOT NULL), countIf(first_name IS NULL), round(countIf(first_name IS NOT NULL) / count() * 100, 2) FROM rpmu.person
UNION ALL
SELECT 'patronymic_name', count(), countIf(patronymic_name IS NOT NULL), countIf(patronymic_name IS NULL), round(countIf(patronymic_name IS NOT NULL) / count() * 100, 2) FROM rpmu.person
UNION ALL
SELECT 'gender_id', count(), countIf(gender_id IS NOT NULL), countIf(gender_id IS NULL), round(countIf(gender_id IS NOT NULL) / count() * 100, 2) FROM rpmu.person;

-- =====================================================================
-- Важные замечания про NULL в ClickHouse
-- =====================================================================

/*
1. NULL сравнения:
   - В ClickHouse: NULL = NULL → 0 (false)
   - Используйте IS NULL / IS NOT NULL для проверки

2. Производительность:
   - Nullable() добавляет ~20% overhead на размер
   - Каждая Nullable колонка хранит отдельный битмап для NULL значений

3. Функции с NULL:
   - ifNull(column, default_value) - заменить NULL на значение
   - isNull(column) - проверка на NULL
   - isNotNull(column) - проверка на NOT NULL
   - assumeNotNull(column) - убрать Nullable (опасно!)

4. Агрегации с NULL:
   - count(column) - не считает NULL
   - count(*) - считает все строки включая NULL
   - avg(column) - игнорирует NULL
   - sum(column) - игнорирует NULL

5. ORDER BY с NULL:
   - NULL считается меньше любого значения
   - Используйте ifNull() в ORDER BY для контроля

Пример:
SELECT * FROM rpmu.person
ORDER BY ifNull(last_name, 'ЯЯЯЯ')  -- NULL будут в конце
LIMIT 100;
*/

-- =====================================================================
-- ОЧИСТКА
-- =====================================================================

/*
DROP TABLE IF EXISTS rpmu.person ON CLUSTER dwh_cluster;
DROP TABLE IF EXISTS rpmu.d_gender ON CLUSTER dwh_cluster;
DROP TABLE IF EXISTS rpmu.d_nationality ON CLUSTER dwh_cluster;
DROP TABLE IF EXISTS rpmu.d_citizenship ON CLUSTER dwh_cluster;
DROP DATABASE IF EXISTS rpmu ON CLUSTER dwh_cluster;
*/
