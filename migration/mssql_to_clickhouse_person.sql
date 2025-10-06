-- =====================================================================
-- Миграция таблицы person из MS SQL Server в ClickHouse
-- =====================================================================
-- Источник: rpmu.person.person (MS SQL)
-- Назначение: rpmu.person (ClickHouse cluster)
--
-- Особенности миграции:
-- 1. uniqueidentifier (GUID) → String или UUID
-- 2. varchar → String или LowCardinality(String)
-- 3. datetime → DateTime
-- 4. bit → UInt8 (0/1)
-- 5. Индексы MS SQL → ORDER BY в ClickHouse
-- 6. Foreign Keys → игнорируются (ClickHouse не поддерживает FK)
-- =====================================================================

-- =====================================================================
-- ВАРИАНТ 1: Максимальная производительность (рекомендуется)
-- =====================================================================

-- Шаг 1: Создать базу данных
CREATE DATABASE IF NOT EXISTS rpmu ON CLUSTER dwh_cluster;

-- Шаг 2: Реплицируемая таблица person
CREATE TABLE rpmu.person ON CLUSTER dwh_cluster
(
    -- Основные поля
    `id` UUID,                                  -- uniqueidentifier → UUID
    `iin` String,                               -- IIN (12 цифр) - уникальный идентификатор
    `last_name` LowCardinality(String),         -- Фамилия (ограниченное число значений)
    `first_name` LowCardinality(String),        -- Имя
    `patronymic_name` LowCardinality(String),   -- Отчество

    -- Даты
    `birth_date` DateTime,                      -- Дата рождения
    `death_date` DateTime DEFAULT toDateTime(0), -- Дата смерти (0 если жив)
    `departure_date` DateTime DEFAULT toDateTime(0), -- Дата выбытия

    -- Справочники (UUID → String для joinов)
    `gender_id` UUID,                           -- Пол
    `nationality_id` UUID,                      -- Национальность
    `citizenship_id` UUID,                      -- Гражданство

    -- Флаги (bit → UInt8)
    `is_del` UInt8 DEFAULT 0,                   -- Признак удаления
    `is_gbdfl` UInt8 DEFAULT 0,                 -- GBDFL флаг

    -- Связи
    `parent_id` UUID,                           -- Родитель (self-reference)
    `rpn_id` String,                            -- RPN идентификатор
    `person_attribute_id` UUID,                 -- Атрибуты персоны

    -- Служебные поля (audit)
    `create_date` DateTime,                     -- Дата создания
    `created_by` UUID,                          -- Кто создал
    `update_date` DateTime DEFAULT toDateTime(0), -- Дата обновления
    `updated_by` UUID,                          -- Кто обновил
    `version` Int32 DEFAULT 0                   -- Версия записи (для оптимистичных блокировок)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/person', '{replica}')
PARTITION BY toYYYYMM(birth_date)              -- Партиции по году-месяцу рождения
ORDER BY (iin, rpn_id, id)                     -- Главные индексы из MS SQL
PRIMARY KEY (iin, rpn_id)                      -- Первичный ключ для быстрого поиска
SETTINGS
    index_granularity = 8192,
    allow_nullable_key = 0;

-- Шаг 3: Distributed таблица для запросов
CREATE TABLE rpmu.person_dist ON CLUSTER dwh_cluster
AS rpmu.person
ENGINE = Distributed(dwh_cluster, rpmu, person, sipHash64(iin));

-- =====================================================================
-- Индексы для ускорения поиска
-- =====================================================================

-- Skip Index для поиска по ФИО (аналог IDX_person_iin_fio)
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_fio (last_name, first_name, patronymic_name) TYPE bloom_filter GRANULARITY 4;

-- Skip Index для поиска по датам
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_dates (birth_date, death_date) TYPE minmax GRANULARITY 1;

-- Skip Index для активных (не удаленных) записей
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_is_del is_del TYPE set(2) GRANULARITY 4;

-- =====================================================================
-- ВАРИАНТ 2: С поддержкой NULL (если нужна совместимость)
-- =====================================================================
/*
CREATE TABLE rpmu.person_nullable ON CLUSTER dwh_cluster
(
    `id` UUID,
    `iin` Nullable(String),
    `last_name` Nullable(String),
    `first_name` Nullable(String),
    `patronymic_name` Nullable(String),
    `birth_date` Nullable(DateTime),
    `death_date` Nullable(DateTime),
    `gender_id` Nullable(UUID),
    `nationality_id` Nullable(UUID),
    `citizenship_id` Nullable(UUID),
    `is_del` Nullable(UInt8),
    `parent_id` Nullable(UUID),
    `rpn_id` Nullable(String),
    `create_date` DateTime,
    `created_by` UUID,
    `update_date` Nullable(DateTime),
    `updated_by` Nullable(UUID),
    `version` Nullable(Int32),
    `is_gbdfl` Nullable(UInt8),
    `departure_date` Nullable(DateTime),
    `person_attribute_id` Nullable(UUID)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/person_nullable', '{replica}')
PARTITION BY toYYYYMM(ifNull(birth_date, toDateTime(0)))
ORDER BY (ifNull(iin, ''), ifNull(rpn_id, ''), id)
SETTINGS index_granularity = 8192;
*/

-- =====================================================================
-- Справочные таблицы (для Foreign Keys)
-- =====================================================================

-- Таблица: d_gender (пол)
CREATE TABLE rpmu.d_gender ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),  -- M, F
    `name` LowCardinality(String),  -- Мужской, Женский
    `create_date` DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_gender', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- Таблица: d_nationality (национальность)
CREATE TABLE rpmu.d_nationality ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),
    `name` LowCardinality(String),
    `create_date` DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_nationality', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- Таблица: d_citizenship (гражданство)
CREATE TABLE rpmu.d_citizenship ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),
    `name` LowCardinality(String),
    `create_date` DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_citizenship', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- =====================================================================
-- Проверка созданных таблиц
-- =====================================================================

-- Список таблиц в БД rpmu
SELECT
    database,
    name,
    engine,
    partition_key,
    sorting_key,
    primary_key,
    formatReadableSize(total_bytes) as size
FROM system.tables
WHERE database = 'rpmu'
ORDER BY name;

-- Детальная информация о таблице person
SHOW CREATE TABLE rpmu.person;

-- Проверка индексов
SELECT
    database,
    table,
    name,
    type,
    expr
FROM system.data_skipping_indices
WHERE database = 'rpmu' AND table = 'person';

-- =====================================================================
-- Тестовые данные для проверки
-- =====================================================================

-- Вставка тестовых данных в справочники
INSERT INTO rpmu.d_gender (id, code, name, create_date) VALUES
    (generateUUIDv4(), 'M', 'Мужской', now()),
    (generateUUIDv4(), 'F', 'Женский', now());

INSERT INTO rpmu.d_nationality (id, code, name, create_date) VALUES
    (generateUUIDv4(), 'KZ', 'Казах', now()),
    (generateUUIDv4(), 'RU', 'Русский', now()),
    (generateUUIDv4(), 'UZ', 'Узбек', now());

INSERT INTO rpmu.d_citizenship (id, code, name, create_date) VALUES
    (generateUUIDv4(), 'KZ', 'Казахстан', now()),
    (generateUUIDv4(), 'RU', 'Россия', now());

-- Вставка тестовых персон
INSERT INTO rpmu.person (
    id, iin, last_name, first_name, patronymic_name,
    birth_date, gender_id, nationality_id, citizenship_id,
    is_del, rpn_id, create_date, created_by, version
) VALUES
    (
        generateUUIDv4(),
        '900101300123',  -- IIN
        'Иванов',
        'Иван',
        'Иванович',
        toDateTime('1990-01-01 00:00:00'),
        (SELECT id FROM rpmu.d_gender WHERE code = 'M' LIMIT 1),
        (SELECT id FROM rpmu.d_nationality WHERE code = 'RU' LIMIT 1),
        (SELECT id FROM rpmu.d_citizenship WHERE code = 'KZ' LIMIT 1),
        0,  -- is_del
        'RPN001',
        now(),
        generateUUIDv4(),
        1
    ),
    (
        generateUUIDv4(),
        '950505400456',
        'Петров',
        'Петр',
        'Петрович',
        toDateTime('1995-05-05 00:00:00'),
        (SELECT id FROM rpmu.d_gender WHERE code = 'M' LIMIT 1),
        (SELECT id FROM rpmu.d_nationality WHERE code = 'KZ' LIMIT 1),
        (SELECT id FROM rpmu.d_citizenship WHERE code = 'KZ' LIMIT 1),
        0,
        'RPN002',
        now(),
        generateUUIDv4(),
        1
    );

-- =====================================================================
-- Тестовые запросы для оценки производительности
-- =====================================================================

-- 1. Поиск по IIN (аналог IDX_person_iin_unique)
SELECT *
FROM rpmu.person
WHERE iin = '900101300123'
SETTINGS max_threads = 16;

-- 2. Поиск по ФИО (аналог IDX_person_iin_fio)
SELECT *
FROM rpmu.person
WHERE iin = '900101300123'
  AND last_name = 'Иванов'
  AND first_name = 'Иван'
  AND patronymic_name = 'Иванович';

-- 3. Поиск по RPN_ID (аналог CLUSTERED INDEX)
SELECT *
FROM rpmu.person
WHERE rpn_id = 'RPN001';

-- 4. Аналитический запрос: количество по годам рождения
SELECT
    toYear(birth_date) as birth_year,
    count() as total,
    countIf(is_del = 0) as active,
    countIf(death_date > toDateTime(0)) as deceased
FROM rpmu.person
GROUP BY birth_year
ORDER BY birth_year DESC
SETTINGS max_threads = 24;

-- 5. JOIN со справочниками (проверка связей)
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

-- 6. Проверка производительности партиций
SELECT
    partition,
    count() as rows,
    formatReadableSize(sum(bytes_on_disk)) as size_on_disk,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) as compression_ratio
FROM system.parts
WHERE database = 'rpmu' AND table = 'person' AND active
GROUP BY partition
ORDER BY partition DESC;

-- =====================================================================
-- ОЧИСТКА (если нужно пересоздать)
-- =====================================================================

/*
DROP TABLE IF EXISTS rpmu.person_dist ON CLUSTER dwh_cluster;
DROP TABLE IF EXISTS rpmu.person ON CLUSTER dwh_cluster;
DROP TABLE IF EXISTS rpmu.d_gender ON CLUSTER dwh_cluster;
DROP TABLE IF EXISTS rpmu.d_nationality ON CLUSTER dwh_cluster;
DROP TABLE IF EXISTS rpmu.d_citizenship ON CLUSTER dwh_cluster;
DROP DATABASE IF EXISTS rpmu ON CLUSTER dwh_cluster;
*/
