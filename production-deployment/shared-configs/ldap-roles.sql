-- =====================================================================
-- LDAP Integration: Роли для доменных пользователей
-- =====================================================================
--
-- Этот скрипт создает роли в ClickHouse, которые будут автоматически
-- назначаться пользователям из Active Directory по группам
--
-- Prerequisite:
-- 1. Настроить ldap.xml на всех нодах
-- 2. Перезапустить ClickHouse
-- 3. Выполнить этот скрипт от пользователя admin
-- =====================================================================

-- =====================================================================
-- 1. РОЛЬ ДЛЯ АНАЛИТИКОВ (Read-only, быстрые запросы)
-- =====================================================================

CREATE ROLE IF NOT EXISTS ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster
SETTINGS
    -- Ограничения для аналитических запросов
    readonly = 1,                          -- Только чтение
    max_memory_usage = 10737418240,        -- 10 GB
    max_execution_time = 300,              -- 5 минут
    max_threads = 16,                      -- Параллельность
    max_rows_to_read = 1000000000,         -- Максимум 1B строк
    max_bytes_to_read = 107374182400,      -- Максимум 100 GB

    -- Запреты на тяжелые операции
    allow_introspection_functions = 0,     -- Без системных функций
    max_ast_elements = 50000,              -- Сложность запроса
    max_expanded_ast_elements = 500000;

-- Права на чтение всех данных
GRANT SELECT ON *.* TO ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster;
GRANT SELECT ON system.* TO ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster;

-- Разрешить создание временных таблиц для промежуточных расчетов
GRANT CREATE TEMPORARY TABLE ON *.* TO ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster;

-- Показать информацию о роли
SHOW CREATE ROLE ROLE_ClickHouse_Analytics;
SHOW GRANTS FOR ROLE_ClickHouse_Analytics;

-- =====================================================================
-- 2. РОЛЬ ДЛЯ ОТЧЕТОВ (Read-only, тяжелые запросы)
-- =====================================================================

CREATE ROLE IF NOT EXISTS ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster
SETTINGS
    -- Увеличенные лимиты для отчетов
    readonly = 1,                          -- Только чтение
    max_memory_usage = 32212254720,        -- 30 GB
    max_execution_time = 1800,             -- 30 минут
    max_threads = 24,                      -- Больше параллельности
    max_rows_to_read = 10000000000,        -- Максимум 10B строк
    max_bytes_to_read = 1073741824000,     -- Максимум 1 TB

    -- JOIN настройки
    max_bytes_in_join = 10737418240,       -- 10 GB для JOIN
    join_algorithm = 'hash',               -- Алгоритм JOIN

    -- Разрешить сложные запросы
    max_ast_elements = 100000,
    max_expanded_ast_elements = 1000000;

-- Права на чтение всех данных
GRANT SELECT ON *.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;
GRANT SELECT ON system.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;

-- Разрешить создание временных таблиц и VIEW
GRANT CREATE TEMPORARY TABLE ON *.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;
GRANT CREATE VIEW ON *.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;

-- Показать информацию о роли
SHOW CREATE ROLE ROLE_ClickHouse_Reports;
SHOW GRANTS FOR ROLE_ClickHouse_Reports;

-- =====================================================================
-- 3. РОЛЬ ДЛЯ АДМИНИСТРАТОРОВ (опционально)
-- =====================================================================

CREATE ROLE IF NOT EXISTS ROLE_ClickHouse_Admins ON CLUSTER dwh_cluster;

-- Полные права на все
GRANT ALL ON *.* TO ROLE_ClickHouse_Admins ON CLUSTER dwh_cluster;

-- Право управлять пользователями и ролями
GRANT ACCESS MANAGEMENT ON *.* TO ROLE_ClickHouse_Admins ON CLUSTER dwh_cluster;

-- Показать информацию о роли
SHOW CREATE ROLE ROLE_ClickHouse_Admins;
SHOW GRANTS FOR ROLE_ClickHouse_Admins;

-- =====================================================================
-- ПРОВЕРКА НАСТРОЕК
-- =====================================================================

-- Список всех ролей
SELECT name, storage FROM system.roles WHERE name LIKE 'ROLE_%';

-- Проверка прав для роли
SHOW GRANTS FOR ROLE_ClickHouse_Analytics;
SHOW GRANTS FOR ROLE_ClickHouse_Reports;

-- =====================================================================
-- ТЕСТИРОВАНИЕ LDAP АВТОРИЗАЦИИ
-- =====================================================================

-- После настройки LDAP, пользователи из AD смогут логиниться так:
-- clickhouse-client -h 192.168.9.113 --port 9090 -u "DOMAIN\username" --password "ad_password"
-- или
-- clickhouse-client -h 192.168.9.113 --port 9090 -u "username@domain.local" --password "ad_password"

-- Для проверки текущего пользователя и его ролей:
SELECT currentUser();
SELECT * FROM system.current_roles;
SELECT * FROM system.enabled_roles;

-- =====================================================================
-- TROUBLESHOOTING
-- =====================================================================

-- Если пользователь не может авторизоваться, проверить логи:
-- docker logs clickhouse-01 | grep -i ldap

-- Проверить подключение к LDAP вручную:
-- ldapsearch -x -H ldap://ldap.company.local:389 -D "CN=clickhouse-svc,OU=Service Accounts,DC=company,DC=local" -w "password" -b "OU=Users,DC=company,DC=local" "(sAMAccountName=username)"
