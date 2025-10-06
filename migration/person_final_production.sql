-- =====================================================================
-- ФИНАЛЬНАЯ КОНФИГУРАЦИЯ: Таблица rpmu.person для Production
-- =====================================================================
-- Дата создания: 2025-10-06
-- Источник: MS SQL Server rpmu.person.person
-- Назначение: ClickHouse DWH Cluster (3 ноды)
-- Архитектура: 1 шард, 3 реплики
-- =====================================================================

-- =====================================================================
-- ШАГ 1: Создать базу данных
-- =====================================================================

CREATE DATABASE IF NOT EXISTS rpmu ON CLUSTER dwh_cluster;

-- =====================================================================
-- ШАГ 2: Создать таблицу person (реплицируемая)
-- =====================================================================

CREATE TABLE rpmu.person ON CLUSTER dwh_cluster
(
    -- =================================================================
    -- NOT NULL поля (обязательные в MS SQL)
    -- =================================================================
    `id` UUID,                              -- uniqueidentifier NOT NULL (PK)
    `create_date` DateTime64(3),            -- datetime NOT NULL
    `created_by` UUID,                      -- uniqueidentifier NOT NULL

    -- =================================================================
    -- NULLABLE поля (могут быть NULL в MS SQL)
    -- =================================================================

    -- Персональные данные
    `iin` Nullable(String),                 -- varchar(255) NULL - ИИН
    `last_name` Nullable(String),           -- varchar(255) NULL - Фамилия
    `first_name` Nullable(String),          -- varchar(255) NULL - Имя
    `patronymic_name` Nullable(String),     -- varchar(255) NULL - Отчество

    -- Даты (строки для совместимости с MS SQL экспортом)
    `birth_date` Nullable(String),          -- datetime NULL - Дата рождения
    `death_date` Nullable(String),          -- datetime NULL - Дата смерти
    `departure_date` Nullable(String),      -- datetime NULL - Дата выбытия

    -- Справочники (UUID)
    `gender_id` Nullable(UUID),             -- uniqueidentifier NULL - Пол
    `nationality_id` Nullable(UUID),        -- uniqueidentifier NULL - Национальность
    `citizenship_id` Nullable(UUID),        -- uniqueidentifier NULL - Гражданство

    -- Флаги
    `is_del` Nullable(UInt8),               -- bit NULL - Признак удаления
    `is_gbdfl` Nullable(UInt8),             -- bit NULL - GBDFL флаг

    -- Связи
    `parent_id` Nullable(UUID),             -- uniqueidentifier NULL - Родитель
    `rpn_id` Nullable(String),              -- varchar(255) NULL - RPN ID
    `person_attribute_id` Nullable(UUID),   -- uniqueidentifier NULL - Атрибуты

    -- Служебные поля
    `update_date` Nullable(DateTime64(3)),  -- datetime NULL - Дата обновления
    `updated_by` Nullable(UUID),            -- uniqueidentifier NULL - Кто обновил
    `version` Nullable(Int32)               -- int NULL - Версия записи
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/person', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- =====================================================================
-- ШАГ 3: Добавить индексы для оптимизации поиска
-- =====================================================================

-- Индекс по ИИН (уникальный идентификатор в MS SQL)
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_iin iin TYPE bloom_filter GRANULARITY 4;

-- Индекс по ФИО
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_fio (last_name, first_name, patronymic_name) TYPE bloom_filter GRANULARITY 4;

-- Индекс по RPN_ID
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_rpn_id rpn_id TYPE bloom_filter GRANULARITY 4;

-- Индекс для фильтрации удаленных записей
ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_is_del is_del TYPE set(3) GRANULARITY 4;

-- =====================================================================
-- ШАГ 4: Проверка создания таблицы
-- =====================================================================

-- Проверить что таблица создана на всех нодах
SELECT
    hostName() as node,
    database,
    name,
    engine,
    sorting_key,
    primary_key,
    formatReadableSize(total_bytes) as size
FROM cluster('dwh_cluster', system.tables)
WHERE database = 'rpmu' AND name = 'person';

-- Должно вернуть 3 строки (по одной на каждую ноду)

-- =====================================================================
-- ШАГ 5: Проверка индексов
-- =====================================================================

SELECT
    database,
    table,
    name as index_name,
    type as index_type,
    expr as index_expression
FROM system.data_skipping_indices
WHERE database = 'rpmu' AND table = 'person';

-- =====================================================================
-- ПРИМЕРЫ ВСТАВКИ ДАННЫХ
-- =====================================================================

-- Пример 1: Вставка с полным набором данных
INSERT INTO rpmu.person (
    id, create_date, created_by,
    iin, last_name, first_name, patronymic_name,
    birth_date, gender_id, nationality_id, citizenship_id,
    is_del, rpn_id, version
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
    '123e4567-e89b-12d3-a456-426614174002',
    '123e4567-e89b-12d3-a456-426614174003',
    0,
    'RPN001',
    1
);

-- Пример 2: Вставка с NULL значениями
INSERT INTO rpmu.person (
    id, create_date, created_by,
    iin, last_name, first_name,
    birth_date, is_del, version
) VALUES (
    '650e8400-e29b-41d4-a716-446655440001',
    '2024-01-02 14:00:00.000',
    '123e4567-e89b-12d3-a456-426614174000',
    '850505400456',
    'Петров',
    'Петр',
    '1985-05-05 00:00:00.000',
    0,
    1
);
-- patronymic_name, gender_id, nationality_id, citizenship_id = NULL

-- =====================================================================
-- ПРОВЕРОЧНЫЕ ЗАПРОСЫ
-- =====================================================================

-- 1. Простая выборка
SELECT * FROM rpmu.person LIMIT 10;

-- 2. Поиск по ИИН
SELECT * FROM rpmu.person WHERE iin = '900101300123';

-- 3. Поиск по ФИО
SELECT * FROM rpmu.person
WHERE last_name = 'Иванов'
  AND first_name = 'Иван';

-- 4. Активные записи (не удаленные)
SELECT * FROM rpmu.person
WHERE is_del = 0 OR is_del IS NULL
LIMIT 100;

-- 5. Подсчет общего количества
SELECT count() as total FROM rpmu.person;

-- 6. Проверка репликации (данные на всех нодах)
SELECT
    hostName() as node,
    count() as rows
FROM cluster('dwh_cluster', rpmu.person)
GROUP BY hostName();

-- =====================================================================
-- СПРАВОЧНЫЕ ТАБЛИЦЫ
-- =====================================================================

-- Таблица: d_gender (пол)
CREATE TABLE rpmu.d_gender ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),
    `name` LowCardinality(String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_gender', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- Таблица: d_nationality (национальность)
CREATE TABLE rpmu.d_nationality ON CLUSTER dwh_cluster
(
    `id` UUID,
    `code` LowCardinality(String),
    `name` LowCardinality(String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/d_nationality', '{replica}')
ORDER BY id
SETTINGS index_granularity = 8192;

-- Таблица: d_citizenship (гражданство)
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
-- ТЕСТОВЫЕ ДАННЫЕ ДЛЯ СПРАВОЧНИКОВ
-- =====================================================================

-- Пол
INSERT INTO rpmu.d_gender VALUES
    (generateUUIDv4(), 'M', 'Мужской'),
    (generateUUIDv4(), 'F', 'Женский');

-- Национальности
INSERT INTO rpmu.d_nationality VALUES
    (generateUUIDv4(), 'KZ', 'Казах'),
    (generateUUIDv4(), 'RU', 'Русский'),
    (generateUUIDv4(), 'UZ', 'Узбек'),
    (generateUUIDv4(), 'UY', 'Уйгур'),
    (generateUUIDv4(), 'TT', 'Татарин');

-- Гражданство
INSERT INTO rpmu.d_citizenship VALUES
    (generateUUIDv4(), 'KZ', 'Казахстан'),
    (generateUUIDv4(), 'RU', 'Россия'),
    (generateUUIDv4(), 'UZ', 'Узбекистан');

-- =====================================================================
-- JOIN ЗАПРОСЫ СО СПРАВОЧНИКАМИ
-- =====================================================================

SELECT
    p.id,
    p.iin,
    p.last_name,
    p.first_name,
    p.patronymic_name,
    ifNull(g.name, 'Не указан') as gender,
    ifNull(n.name, 'Не указана') as nationality,
    ifNull(c.name, 'Не указано') as citizenship
FROM rpmu.person p
LEFT JOIN rpmu.d_gender g ON p.gender_id = g.id
LEFT JOIN rpmu.d_nationality n ON p.nationality_id = n.id
LEFT JOIN rpmu.d_citizenship c ON p.citizenship_id = c.id
WHERE p.is_del = 0 OR p.is_del IS NULL
LIMIT 100;

-- =====================================================================
-- ОПТИМИЗАЦИЯ И МОНИТОРИНГ
-- =====================================================================

-- Размер таблицы на диске
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) as size_on_disk,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) as compression_ratio,
    count() as parts_count
FROM system.parts
WHERE database = 'rpmu' AND table = 'person' AND active
GROUP BY table;

-- Количество строк по нодам
SELECT
    hostName() as node,
    count() as rows,
    formatReadableSize(sum(data_compressed_bytes)) as compressed_size
FROM cluster('dwh_cluster', system.parts)
WHERE database = 'rpmu' AND table = 'person' AND active
GROUP BY hostName();

-- Медленные запросы к таблице person
SELECT
    query_start_time,
    query_duration_ms / 1000 as duration_sec,
    user,
    substring(query, 1, 100) as query_preview,
    read_rows,
    formatReadableSize(read_bytes) as read_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%rpmu.person%'
  AND query_duration_ms > 1000
ORDER BY query_start_time DESC
LIMIT 20;

-- =====================================================================
-- УДАЛЕНИЕ (если нужно пересоздать)
-- =====================================================================

/*
-- ВНИМАНИЕ: Это удалит все данные!

-- Удалить таблицу на всех нодах
DROP TABLE IF EXISTS rpmu.person ON CLUSTER dwh_cluster SYNC;

-- Удалить справочники
DROP TABLE IF EXISTS rpmu.d_gender ON CLUSTER dwh_cluster SYNC;
DROP TABLE IF EXISTS rpmu.d_nationality ON CLUSTER dwh_cluster SYNC;
DROP TABLE IF EXISTS rpmu.d_citizenship ON CLUSTER dwh_cluster SYNC;

-- Удалить базу данных
DROP DATABASE IF EXISTS rpmu ON CLUSTER dwh_cluster SYNC;
*/

-- =====================================================================
-- ВАЖНЫЕ ЗАМЕЧАНИЯ
-- =====================================================================

/*
1. ПОРЯДОК ПОЛЕЙ ПРИ INSERT:
   - Используйте явное указание колонок: INSERT INTO rpmu.person (id, iin, ...) VALUES (...)
   - Тогда порядок не важен

2. NULL ЗНАЧЕНИЯ:
   - Используйте NULL для пустых значений
   - Не используйте пустые строки '' вместо NULL для UUID полей
   - ClickHouse автоматически обрабатывает NULL в ORDER BY

3. UUID ФОРМАТ:
   - Вставляйте UUID как строки: '550e8400-e29b-41d4-a716-446655440000'
   - ClickHouse автоматически конвертирует в тип UUID

4. DATETIME ФОРМАТ:
   - Формат: 'YYYY-MM-DD HH:MM:SS.mmm'
   - Пример: '2024-01-01 12:00:00.000'

5. РЕПЛИКАЦИЯ:
   - Данные автоматически реплицируются между всеми 3 нодами
   - INSERT на любую ноду → данные появятся везде
   - Можно читать с любой ноды через HAProxy

6. ПРОИЗВОДИТЕЛЬНОСТЬ:
   - Вставка: 100K-500K строк/сек (зависит от сложности данных)
   - Чтение: <100ms для простых запросов по индексам
   - JOIN: быстрый для справочников (<1M строк)
*/
