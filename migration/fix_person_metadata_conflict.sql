-- =====================================================================
-- Исправление конфликта метаданных ZooKeeper для таблицы person
-- =====================================================================
--
-- Проблема:
-- METADATA_MISMATCH - старая схема в ZooKeeper конфликтует с новой
--
-- Причина:
-- PRIMARY KEY содержал ifNull() функции, которые не поддерживаются
-- в ReplicatedMergeTree
--
-- Решение:
-- 1. Полностью удалить таблицу
-- 2. Очистить ZooKeeper
-- 3. Пересоздать без ifNull() в ORDER BY / PRIMARY KEY
-- =====================================================================

-- =====================================================================
-- ШАГ 1: Удалить таблицу на ВСЕХ нодах
-- =====================================================================

-- ВАЖНО: Выполнить на каждой ноде ОТДЕЛЬНО!
-- (Не используем ON CLUSTER чтобы точно очистить метаданные)

-- Подключиться к clickhouse-01 (192.168.9.110) и выполнить:
DROP TABLE IF EXISTS rpmu.person SYNC;

-- Подключиться к clickhouse-02 (192.168.9.111) и выполнить:
DROP TABLE IF EXISTS rpmu.person SYNC;

-- Подключиться к clickhouse-03 (192.168.9.112) и выполнить:
DROP TABLE IF EXISTS rpmu.person SYNC;

-- =====================================================================
-- ШАГ 2: Очистить ZooKeeper метаданные (опционально)
-- =====================================================================

/*
Если DROP SYNC не помог, выполнить вручную:

# На любой VM (VM-1, VM-2 или VM-3) выполнить:
docker exec -it zookeeper-01 zkCli.sh

# В zkCli интерактивной оболочке:
ls /clickhouse/tables
deleteall /clickhouse/tables/01/rpmu/person
quit

# Повторить для zookeeper-02 и zookeeper-03 если нужно
*/

-- =====================================================================
-- ШАГ 3: Пересоздать таблицу с ПРАВИЛЬНОЙ схемой
-- =====================================================================

-- Создать базу данных (если не существует)
CREATE DATABASE IF NOT EXISTS rpmu ON CLUSTER dwh_cluster;

-- Создать таблицу БЕЗ ifNull() в ORDER BY / PRIMARY KEY
CREATE TABLE rpmu.person ON CLUSTER dwh_cluster
(
    -- =================================================================
    -- NOT NULL поля (обязательные)
    -- =================================================================
    `id` String,                                -- uniqueidentifier NOT NULL
    `create_date` String,                       -- datetime NOT NULL
    `created_by` String,                        -- uniqueidentifier NOT NULL

    -- =================================================================
    -- NULLABLE поля
    -- =================================================================
    `iin` Nullable(String),
    `last_name` Nullable(String),
    `first_name` Nullable(String),
    `patronymic_name` Nullable(String),
    `birth_date` Nullable(String),
    `death_date` Nullable(String),
    `departure_date` Nullable(String),
    `gender_id` Nullable(String),
    `nationality_id` Nullable(String),
    `citizenship_id` Nullable(String),
    `is_del` Nullable(UInt8),
    `is_gbdfl` Nullable(UInt8),
    `parent_id` Nullable(String),
    `rpn_id` Nullable(String),
    `person_attribute_id` Nullable(String),
    `update_date` Nullable(String),
    `updated_by` Nullable(String),
    `version` Nullable(Int32),

    -- =================================================================
    -- MATERIALIZED колонки
    -- =================================================================
    `id_uuid` UUID MATERIALIZED toUUIDOrZero(id),
    `gender_id_uuid` UUID MATERIALIZED toUUIDOrZero(ifNull(gender_id, '')),
    `nationality_id_uuid` UUID MATERIALIZED toUUIDOrZero(ifNull(nationality_id, '')),
    `citizenship_id_uuid` UUID MATERIALIZED toUUIDOrZero(ifNull(citizenship_id, '')),
    `created_by_uuid` UUID MATERIALIZED toUUIDOrZero(created_by),
    `birth_date_dt` Nullable(DateTime) MATERIALIZED parseDateTimeBestEffortOrNull(birth_date),
    `death_date_dt` Nullable(DateTime) MATERIALIZED parseDateTimeBestEffortOrNull(death_date),
    `create_date_dt` DateTime MATERIALIZED parseDateTimeBestEffortOrZero(create_date),
    `update_date_dt` Nullable(DateTime) MATERIALIZED parseDateTimeBestEffortOrNull(update_date),
    `full_name` String MATERIALIZED concat(
        ifNull(last_name, ''), ' ',
        ifNull(first_name, ''), ' ',
        ifNull(patronymic_name, '')
    )
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rpmu/person', '{replica}')
PARTITION BY toYYYYMM(ifNull(birth_date_dt, toDateTime('1970-01-01')))
-- КРИТИЧНО: БЕЗ ifNull() в ORDER BY и PRIMARY KEY!
ORDER BY (iin, rpn_id, id)
SETTINGS
    index_granularity = 8192,
    allow_nullable_key = 1;  -- Разрешить Nullable в сортировочном ключе

-- =====================================================================
-- ШАГ 4: Проверка создания
-- =====================================================================

-- Проверить что таблица создана на всех нодах
SELECT
    hostName() as node,
    database,
    name,
    engine,
    partition_key,
    sorting_key,
    primary_key
FROM cluster('dwh_cluster', system.tables)
WHERE database = 'rpmu' AND name = 'person';

-- Ожидаемый результат:
-- 3 строки (по одной на каждую ноду)
-- sorting_key и primary_key БЕЗ ifNull()

-- =====================================================================
-- ШАГ 5: Добавить индексы
-- =====================================================================

ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_fio (last_name, first_name, patronymic_name) TYPE bloom_filter GRANULARITY 4;

ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_dates (birth_date_dt, death_date_dt) TYPE minmax GRANULARITY 1;

ALTER TABLE rpmu.person ON CLUSTER dwh_cluster
ADD INDEX idx_is_del is_del TYPE set(3) GRANULARITY 4;

-- =====================================================================
-- ШАГ 6: Тестовая вставка
-- =====================================================================

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

-- Проверить вставку
SELECT * FROM rpmu.person;

-- Проверить репликацию (должна быть на всех нодах)
SELECT
    hostName() as node,
    count() as rows
FROM cluster('dwh_cluster', rpmu.person)
GROUP BY hostName();

-- =====================================================================
-- ВАЖНО: Как работать с NULL в ORDER BY
-- =====================================================================

/*
Проблема:
ORDER BY (iin, rpn_id, id) где iin и rpn_id могут быть NULL

Решение ClickHouse:
- ClickHouse автоматически обрабатывает NULL в сортировке
- NULL считается "меньше" любого значения
- Не нужно использовать ifNull() в ORDER BY!

Пример:
iin = NULL    → сортируется первым
iin = ''      → после NULL
iin = '123'   → после пустой строки

Если нужен другой порядок, используйте в SELECT:
SELECT * FROM rpmu.person
ORDER BY ifNull(iin, 'ZZZZZ')  -- NULL будут в конце
LIMIT 100;

НО: в CREATE TABLE ORDER BY - только колонки, БЕЗ функций!
*/

-- =====================================================================
-- Troubleshooting
-- =====================================================================

-- Если всё ещё ошибка METADATA_MISMATCH:

-- 1. Проверить что таблица удалена на всех нодах:
SELECT hostName(), count()
FROM cluster('dwh_cluster', system.tables)
WHERE database = 'rpmu' AND name = 'person'
GROUP BY hostName();

-- Если есть записи - удалить вручную на каждой ноде

-- 2. Проверить ZooKeeper:
SELECT * FROM system.zookeeper WHERE path = '/clickhouse/tables/01/rpmu';

-- Если есть person - очистить через zkCli (см. выше)

-- 3. Перезапустить ClickHouse на всех нодах:
-- docker restart clickhouse-01
-- docker restart clickhouse-02
-- docker restart clickhouse-03

-- =====================================================================
-- Альтернативное решение: без Nullable в ORDER BY
-- =====================================================================

/*
Если allow_nullable_key = 1 не помогает, используйте DEFAULT вместо Nullable:

CREATE TABLE rpmu.person_alternative ON CLUSTER dwh_cluster
(
    `id` String,
    `create_date` String,
    `created_by` String,
    `iin` String DEFAULT '',              -- НЕ Nullable, пустая строка по умолчанию
    `rpn_id` String DEFAULT '',           -- НЕ Nullable
    `last_name` String DEFAULT '',
    `first_name` String DEFAULT '',
    `birth_date` String DEFAULT '',
    ...
)
ENGINE = ReplicatedMergeTree(...)
ORDER BY (iin, rpn_id, id);  -- Теперь нет NULL проблем

Минусы:
- Теряется различие между NULL и пустой строкой ''
- Нужно конвертировать NULL → '' при импорте из MS SQL

Плюсы:
- Производительнее (нет Nullable overhead)
- Проще работать (нет NULL логики)
*/
