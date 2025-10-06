-- =====================================================================
-- Таблица person для импорта данных из MS SQL Server
-- =====================================================================
--
-- Данные приходят из MS SQL в формате:
-- - UUID → VARCHAR(36) строки
-- - DateTime → VARCHAR(23) строки формата '2024-01-01 12:00:00.000'
-- - bit → TINYINT (0/1)
--
-- Стратегия:
-- 1. Принимаем данные "как есть" (строки)
-- 2. Используем MATERIALIZED колонки для типизированных значений
-- 3. Партиционируем и сортируем по вычисляемым колонкам
-- =====================================================================

-- Шаг 1: Создать базу данных
CREATE DATABASE IF NOT EXISTS rpmu ON CLUSTER dwh_cluster;

-- Шаг 2: Основная таблица person (прием сырых данных из MS SQL)
CREATE TABLE rpmu.person ON CLUSTER dwh_cluster
(
    -- =================================================================
    -- ИСХОДНЫЕ ДАННЫЕ ИЗ MS SQL (все как строки)
    -- =================================================================

    -- Основные поля
    `id` String,                                -- CONVERT(VARCHAR(36), id)
    `iin` String,                               -- IIN (12 цифр)
    `last_name` String DEFAULT '',              -- Фамилия
    `first_name` String DEFAULT '',             -- Имя
    `patronymic_name` String DEFAULT '',        -- Отчество

    -- Даты (строки формата '2024-01-01 12:00:00.000')
    `birth_date` String,                        -- CONVERT(VARCHAR(23), birth_date, 121)
    `death_date` String DEFAULT '',             -- CONVERT(VARCHAR(23), death_date, 121)
    `departure_date` String DEFAULT '',         -- CONVERT(VARCHAR(23), departure_date, 121)

    -- Справочники (UUID как строки)
    `gender_id` String DEFAULT '',              -- CONVERT(VARCHAR(36), gender_id)
    `nationality_id` String DEFAULT '',         -- CONVERT(VARCHAR(36), nationality_id)
    `citizenship_id` String DEFAULT '',         -- CONVERT(VARCHAR(36), citizenship_id)

    -- Флаги
    `is_del` UInt8 DEFAULT 0,                   -- CAST(is_del AS TINYINT)
    `is_gbdfl` UInt8 DEFAULT 0,                 -- CAST(is_gbdfl AS TINYINT)

    -- Связи
    `parent_id` String DEFAULT '',              -- CONVERT(VARCHAR(36), parent_id)
    `rpn_id` String DEFAULT '',                 -- RPN идентификатор
    `person_attribute_id` String DEFAULT '',    -- CONVERT(VARCHAR(36), person_attribute_id)

    -- Служебные поля (audit)
    `create_date` String,                       -- CONVERT(VARCHAR(23), create_date, 121)
    `created_by` String,                        -- CONVERT(VARCHAR(36), created_by)
    `update_date` String DEFAULT '',            -- CONVERT(VARCHAR(23), update_date, 121)
    `updated_by` String DEFAULT '',             -- CONVERT(VARCHAR(36), updated_by)
    `version` Int32 DEFAULT 0,                  -- Версия записи

    -- =================================================================
    -- ТИПИЗИРОВАННЫЕ КОЛОНКИ (автоматически вычисляются)
    -- =================================================================

    -- UUID колонки (для быстрых JOIN)
    `id_uuid` UUID MATERIALIZED toUUIDOrZero(id),
    `gender_id_uuid` UUID MATERIALIZED toUUIDOrZero(gender_id),
    `nationality_id_uuid` UUID MATERIALIZED toUUIDOrZero(nationality_id),
    `citizenship_id_uuid` UUID MATERIALIZED toUUIDOrZero(citizenship_id),
    `created_by_uuid` UUID MATERIALIZED toUUIDOrZero(created_by),

    -- DateTime колонки (для фильтрации по датам)
    `birth_date_dt` DateTime MATERIALIZED parseDateTimeBestEffortOrZero(birth_date),
    `death_date_dt` DateTime MATERIALIZED parseDateTimeBestEffortOrZero(death_date),
    `create_date_dt` DateTime MATERIALIZED parseDateTimeBestEffortOrZero(create_date),
    `update_date_dt` DateTime MATERIALIZED parseDateTimeBestEffortOrZero(update_date),
    `departure_date_dt` DateTime MATERIALIZED parseDateTimeBestEffortOrZero(departure_date)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/person', '{replica}')
PARTITION BY toYYYYMM(birth_date_dt)           -- Партиции по году-месяцу рождения
ORDER BY (iin, rpn_id, id)                     -- Сортировка для быстрого поиска
PRIMARY KEY (iin, rpn_id)                      -- Первичный ключ
SETTINGS
    index_granularity = 8192;

-- =====================================================================
-- Skip индексы для ускорения поиска
-- =====================================================================

-- Индекс по ФИО
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_fio (last_name, first_name, patronymic_name) TYPE bloom_filter GRANULARITY 4;

-- Индекс по датам
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_dates (birth_date_dt, death_date_dt) TYPE minmax GRANULARITY 1;

-- Индекс для фильтрации удаленных
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_is_del is_del TYPE set(2) GRANULARITY 4;

-- =====================================================================
-- Пример INSERT из MS SQL
-- =====================================================================

/*
-- В MS SQL Server выполнить:
SELECT
    CONVERT(VARCHAR(36), id) as id,
    iin,
    last_name,
    first_name,
    patronymic_name,
    CONVERT(VARCHAR(23), birth_date, 121) as birth_date,
    CONVERT(VARCHAR(23), death_date, 121) as death_date,
    CONVERT(VARCHAR(36), gender_id) as gender_id,
    CONVERT(VARCHAR(36), nationality_id) as nationality_id,
    CONVERT(VARCHAR(36), citizenship_id) as citizenship_id,
    CAST(is_del AS TINYINT) as is_del,
    CONVERT(VARCHAR(36), parent_id) as parent_id,
    rpn_id,
    CONVERT(VARCHAR(23), create_date, 121) as create_date,
    CONVERT(VARCHAR(36), created_by) as created_by,
    CONVERT(VARCHAR(23), update_date, 121) as update_date,
    CONVERT(VARCHAR(36), updated_by) as updated_by,
    version,
    CAST(is_gbdfl AS TINYINT) as is_gbdfl,
    CONVERT(VARCHAR(23), departure_date, 121) as departure_date,
    CONVERT(VARCHAR(36), person_attribute_id) as person_attribute_id
FROM rpmu.person.person
WHERE is_del = 0;

-- Экспортировать в CSV и загрузить в ClickHouse:
clickhouse-client -h 192.168.9.113 --port 9090 -u admin --password <pass> --query \
"INSERT INTO rpmu.person FORMAT CSV" < person_export.csv
*/

-- =====================================================================
-- Тестовая вставка
-- =====================================================================

INSERT INTO rpmu.person (
    id, iin, last_name, first_name, patronymic_name,
    birth_date, death_date, gender_id, nationality_id, citizenship_id,
    is_del, parent_id, rpn_id, create_date, created_by,
    update_date, updated_by, version, is_gbdfl, departure_date, person_attribute_id
) VALUES (
    '550e8400-e29b-41d4-a716-446655440000',  -- id как строка
    '900101300123',                          -- iin
    'Иванов',                                -- last_name
    'Иван',                                  -- first_name
    'Иванович',                              -- patronymic_name
    '1990-01-01 00:00:00.000',              -- birth_date (строка)
    '',                                      -- death_date (пусто = жив)
    '123e4567-e89b-12d3-a456-426614174001',  -- gender_id
    '123e4567-e89b-12d3-a456-426614174002',  -- nationality_id
    '123e4567-e89b-12d3-a456-426614174003',  -- citizenship_id
    0,                                       -- is_del
    '',                                      -- parent_id (пусто)
    'RPN001',                                -- rpn_id
    '2024-01-01 12:00:00.000',              -- create_date
    '123e4567-e89b-12d3-a456-426614174004',  -- created_by
    '',                                      -- update_date (пусто)
    '',                                      -- updated_by (пусто)
    1,                                       -- version
    0,                                       -- is_gbdfl
    '',                                      -- departure_date (пусто)
    ''                                       -- person_attribute_id (пусто)
);

-- =====================================================================
-- Проверка данных
-- =====================================================================

-- 1. Просмотр исходных данных (как пришли из MS SQL)
SELECT
    id,
    iin,
    last_name,
    first_name,
    birth_date,          -- строка
    gender_id            -- строка
FROM rpmu.person
LIMIT 5;

-- 2. Просмотр типизированных данных (MATERIALIZED колонки)
SELECT
    id,
    iin,
    last_name,
    first_name,
    birth_date,          -- исходная строка
    birth_date_dt,       -- вычисленная DateTime
    id_uuid,             -- вычисленный UUID
    gender_id_uuid       -- вычисленный UUID
FROM rpmu.person
LIMIT 5;

-- 3. Фильтрация по типизированным колонкам
SELECT *
FROM rpmu.person
WHERE birth_date_dt >= '1990-01-01'
  AND birth_date_dt < '2000-01-01'
  AND is_del = 0;

-- 4. JOIN по UUID (используем MATERIALIZED колонки)
SELECT
    p.iin,
    p.last_name,
    p.first_name,
    g.name as gender
FROM rpmu.person p
LEFT JOIN rpmu.d_gender g ON p.gender_id_uuid = g.id
WHERE p.is_del = 0
LIMIT 10;

-- 5. Аналитика по годам рождения
SELECT
    toYear(birth_date_dt) as birth_year,
    count() as total,
    countIf(is_del = 0) as active
FROM rpmu.person
GROUP BY birth_year
ORDER BY birth_year DESC;

-- =====================================================================
-- Производительность: сравнение String vs MATERIALIZED
-- =====================================================================

-- Медленно (парсинг строки на каждой строке)
SELECT count()
FROM rpmu.person
WHERE parseDateTimeBestEffort(birth_date) >= '1990-01-01';

-- Быстро (использует предвычисленную колонку)
SELECT count()
FROM rpmu.person
WHERE birth_date_dt >= '1990-01-01';

-- =====================================================================
-- Размер данных на диске
-- =====================================================================

SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) as size_on_disk,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) as compression_ratio,
    count() as parts
FROM system.parts
WHERE database = 'rpmu' AND table = 'person' AND active
GROUP BY table;

-- =====================================================================
-- ВАЖНО: Рекомендации по использованию
-- =====================================================================

/*
1. INSERT данных:
   - Используйте исходные колонки (String): id, birth_date, gender_id и т.д.
   - MATERIALIZED колонки заполнятся автоматически

2. SELECT запросы:
   - Для фильтрации используйте MATERIALIZED колонки: birth_date_dt, id_uuid
   - Это в 10-100x быстрее чем парсинг строк

3. JOIN:
   - Используйте *_uuid колонки: gender_id_uuid, nationality_id_uuid
   - JOIN по UUID намного быстрее чем по String

4. Отображение:
   - Для вывода пользователям используйте исходные колонки (String)
   - Они сохраняют точный формат из MS SQL

Пример правильного запроса:
SELECT
    id,                    -- String для вывода
    iin,
    last_name,
    birth_date,            -- String для вывода (сохраняет формат MS SQL)
    gender_id              -- String для вывода
FROM rpmu.person
WHERE birth_date_dt >= '1990-01-01'  -- MATERIALIZED для фильтрации
  AND is_del = 0
LIMIT 100;
*/

-- =====================================================================
-- ОЧИСТКА (если нужно пересоздать)
-- =====================================================================

/*
DROP TABLE IF EXISTS rpmu.person ON CLUSTER dwh_cluster;
DROP DATABASE IF EXISTS rpmu ON CLUSTER dwh_cluster;
*/
