# ClickHouse LDAP Integration - Setup Guide

## Обзор

Интеграция ClickHouse с Active Directory/LDAP позволяет:
- ✅ Использовать доменные учетки вместо локальных паролей
- ✅ Автоматически назначать роли по группам AD
- ✅ Централизованное управление доступом через AD
- ✅ Единый вход (SSO) для всех сервисов

---

## Архитектура

```
Active Directory (LDAP)
        │
        │ 1. Пользователь логинится: username@domain.local
        │
        ▼
  ClickHouse (192.168.9.110-112)
        │
        │ 2. LDAP bind: проверка пароля
        │ 3. LDAP search: поиск групп пользователя
        │
        ▼
  Маппинг групп → роли
  ├─ CN=ClickHouse-Analytics → ROLE_ClickHouse_Analytics (readonly)
  ├─ CN=ClickHouse-Reports → ROLE_ClickHouse_Reports (readonly + heavy queries)
  └─ CN=ClickHouse-Admins → ROLE_ClickHouse_Admins (full access)
```

---

## Шаг 1: Подготовка Active Directory

### 1.1. Создать служебную учетку

В AD создать пользователя для ClickHouse (для поиска в LDAP):

```
Username: clickhouse-svc
Password: <сильный пароль>
OU: Service Accounts
Права: Domain Users (read-only достаточно)
```

### 1.2. Создать группы безопасности

Создать группы в AD для управления доступом:

| Группа | DN | Назначение |
|--------|-----|------------|
| ClickHouse-Analytics | CN=ClickHouse-Analytics,OU=Groups,DC=company,DC=local | Аналитики (read-only) |
| ClickHouse-Reports | CN=ClickHouse-Reports,OU=Groups,DC=company,DC=local | Отчеты (read-only + тяжелые запросы) |
| ClickHouse-Admins | CN=ClickHouse-Admins,OU=Groups,DC=company,DC=local | Администраторы (полный доступ) |

### 1.3. Добавить пользователей в группы

Добавить доменных пользователей в соответствующие группы через Active Directory Users and Computers.

---

## Шаг 2: Настройка ClickHouse LDAP

### 2.1. Создать конфигурацию LDAP

На **каждой VM (VM-1, VM-2, VM-3)** создать файл `/opt/clickhouse/config/ldap.xml`:

```bash
# На VM-1 (192.168.9.110)
sudo nano /opt/clickhouse/config/ldap.xml
```

**Содержимое** (заменить параметры на свои):

```xml
<?xml version="1.0"?>
<clickhouse>
    <ldap_servers>
        <my_ldap_server>
            <!-- LDAP/AD сервер -->
            <host>dc01.company.local</host>
            <port>389</port>

            <!-- Для LDAPS (рекомендуется) раскомментировать: -->
            <!-- <port>636</port> -->
            <!-- <enable_tls>yes</enable_tls> -->
            <!-- <tls_require_cert>demand</tls_require_cert> -->

            <!-- Служебная учетка для поиска -->
            <bind_dn>CN=clickhouse-svc,OU=Service Accounts,DC=company,DC=local</bind_dn>
            <bind_password>STRONG_PASSWORD_HERE</bind_password>

            <!-- Поиск пользователей -->
            <user_dn_detection>
                <base_dn>OU=Users,DC=company,DC=local</base_dn>
                <search_filter>(&amp;(objectClass=user)(sAMAccountName={user_name}))</search_filter>
            </user_dn_detection>

            <!-- Timeout -->
            <verification_cooldown>300</verification_cooldown>
            <operation_timeout>10</operation_timeout>
            <connection_timeout>5</connection_timeout>
            <enable_tls>no</enable_tls>
        </my_ldap_server>
    </ldap_servers>

    <user_directories>
        <ldap>
            <server>my_ldap_server</server>

            <!-- Маппинг групп AD на роли ClickHouse -->
            <role_mapping>
                <base_dn>OU=Groups,DC=company,DC=local</base_dn>
                <search_filter>(&amp;(objectClass=group)(member={user_dn}))</search_filter>
                <attribute>cn</attribute>
                <prefix>ROLE_</prefix>
            </role_mapping>
        </ldap>
    </user_directories>
</clickhouse>
```

**Важно**: Изменить параметры:
- `host` - IP или hostname AD контроллера
- `DC=company,DC=local` - ваш домен (например, `DC=example,DC=com`)
- `bind_dn` и `bind_password` - учетные данные служебной учетки
- `base_dn` для пользователей и групп

### 2.2. Скопировать на все ноды

```bash
# С VM-1 скопировать на VM-2 и VM-3
scp /opt/clickhouse/config/ldap.xml root@192.168.9.111:/opt/clickhouse/config/
scp /opt/clickhouse/config/ldap.xml root@192.168.9.112:/opt/clickhouse/config/
```

### 2.3. Обновить права доступа

```bash
# На всех VM (110, 111, 112)
sudo chown 101:101 /opt/clickhouse/config/ldap.xml
sudo chmod 600 /opt/clickhouse/config/ldap.xml
```

### 2.4. Перезапустить ClickHouse

```bash
# На VM-1
docker restart clickhouse-01

# На VM-2
docker restart clickhouse-02

# На VM-3
docker restart clickhouse-03
```

### 2.5. Проверить логи

```bash
# Проверить успешное подключение к LDAP
docker logs clickhouse-01 2>&1 | grep -i ldap
```

Должно быть:
```
<Information> LDAP server 'my_ldap_server': Connected successfully
```

---

## Шаг 3: Создание ролей в ClickHouse

### 3.1. Подключиться как admin

```bash
clickhouse-client -h 192.168.9.113 --port 9090 --user admin --password <admin_password>
```

### 3.2. Создать роли

Выполнить SQL из файла `ldap-roles.sql`:

```bash
clickhouse-client -h 192.168.9.113 --port 9090 --user admin --password <password> < /opt/shared-configs/ldap-roles.sql
```

Или вручную:

```sql
-- Роль для аналитиков
CREATE ROLE IF NOT EXISTS ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster
SETTINGS
    readonly = 1,
    max_memory_usage = 10737418240,  -- 10 GB
    max_execution_time = 300;        -- 5 минут

GRANT SELECT ON *.* TO ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster;
GRANT SELECT ON system.* TO ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster;
GRANT CREATE TEMPORARY TABLE ON *.* TO ROLE_ClickHouse_Analytics ON CLUSTER dwh_cluster;

-- Роль для отчетов
CREATE ROLE IF NOT EXISTS ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster
SETTINGS
    readonly = 1,
    max_memory_usage = 32212254720,  -- 30 GB
    max_execution_time = 1800;       -- 30 минут

GRANT SELECT ON *.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;
GRANT SELECT ON system.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;
GRANT CREATE TEMPORARY TABLE ON *.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;
GRANT CREATE VIEW ON *.* TO ROLE_ClickHouse_Reports ON CLUSTER dwh_cluster;

-- Роль для администраторов
CREATE ROLE IF NOT EXISTS ROLE_ClickHouse_Admins ON CLUSTER dwh_cluster;
GRANT ALL ON *.* TO ROLE_ClickHouse_Admins ON CLUSTER dwh_cluster;
GRANT ACCESS MANAGEMENT ON *.* TO ROLE_ClickHouse_Admins ON CLUSTER dwh_cluster;
```

### 3.3. Проверить созданные роли

```sql
SELECT name, storage FROM system.roles WHERE name LIKE 'ROLE_%';
```

Вывод:
```
┌─name──────────────────────────┬─storage────┐
│ ROLE_ClickHouse_Analytics     │ replicated │
│ ROLE_ClickHouse_Reports       │ replicated │
│ ROLE_ClickHouse_Admins        │ replicated │
└───────────────────────────────┴────────────┘
```

---

## Шаг 4: Тестирование LDAP авторизации

### 4.1. Добавить пользователя в AD группу

В Active Directory Users and Computers:
1. Найти пользователя (например, `ivanov`)
2. Добавить в группу `ClickHouse-Analytics`

### 4.2. Подключиться с доменными учетками

**Формат 1** (domain\username):
```bash
clickhouse-client -h 192.168.9.113 --port 9090 -u "COMPANY\ivanov" --password "domain_password"
```

**Формат 2** (username@domain):
```bash
clickhouse-client -h 192.168.9.113 --port 9090 -u "ivanov@company.local" --password "domain_password"
```

### 4.3. Проверить роли пользователя

После успешного входа:

```sql
-- Текущий пользователь
SELECT currentUser();

-- Активные роли
SELECT * FROM system.current_roles;

-- Все доступные роли
SELECT * FROM system.enabled_roles;
```

Для пользователя из группы `ClickHouse-Analytics` должно быть:
```
┌─name──────────────────────────┐
│ ROLE_ClickHouse_Analytics     │
└───────────────────────────────┘
```

### 4.4. Тестирование прав доступа

**Аналитик (readonly)**:
```sql
-- Должно работать
SELECT count() FROM system.tables;

-- Должно быть запрещено
INSERT INTO test.table VALUES (1, 'test');
-- Error: Cannot execute query in readonly mode
```

**Пользователь отчетов**:
```sql
-- Должно работать
CREATE TEMPORARY TABLE tmp AS SELECT * FROM system.tables LIMIT 10;
SELECT count() FROM tmp;

-- Тяжелый запрос (до 30 минут)
SELECT ... FROM large_table ...
```

---

## Шаг 5: Подключение через DBeaver

### 5.1. Настройки подключения

1. Открыть DBeaver → Новое подключение → ClickHouse
2. Заполнить параметры:

| Параметр | Значение |
|----------|----------|
| Host | 192.168.9.113 (HAProxy) |
| Port | 8081 (Analytics) или 8082 (Reports) |
| Database | default |
| Username | `COMPANY\ivanov` или `ivanov@company.local` |
| Password | <доменный пароль> |

3. Test Connection → должно подключиться

### 5.2. Выбор endpoint по назначению

| Endpoint | Порт | Для кого |
|----------|------|----------|
| Analytics | 8081 | Быстрые запросы аналитиков (5 мин timeout) |
| Reports | 8082 | Тяжелые отчеты (30 мин timeout) |
| ETL | 8080 | Только для ETL процессов (не для пользователей) |

---

## Troubleshooting

### Проблема 1: "Authentication failed"

**Причины**:
- Неверный пароль AD
- Неправильный формат username (попробовать `DOMAIN\user` или `user@domain.local`)
- Служебная учетка не имеет прав на чтение AD

**Диагностика**:
```bash
# Проверить LDAP подключение вручную
docker exec clickhouse-01 ldapsearch -x \
  -H ldap://dc01.company.local:389 \
  -D "CN=clickhouse-svc,OU=Service Accounts,DC=company,DC=local" \
  -w "password" \
  -b "OU=Users,DC=company,DC=local" \
  "(sAMAccountName=ivanov)"
```

Должно вернуть информацию о пользователе.

### Проблема 2: "User has no roles"

**Причины**:
- Пользователь не добавлен в группу AD
- Неправильный `base_dn` для групп в ldap.xml
- Роли не созданы в ClickHouse

**Решение**:
```sql
-- Проверить существование ролей
SELECT name FROM system.roles WHERE name LIKE 'ROLE_%';

-- Проверить маппинг вручную (от admin)
-- Временно назначить роль
GRANT ROLE_ClickHouse_Analytics TO 'ivanov@company.local';
```

### Проблема 3: "Cannot connect to LDAP server"

**Причины**:
- Неверный IP/hostname LDAP сервера
- Firewall блокирует порт 389/636
- LDAP сервер недоступен

**Решение**:
```bash
# Проверить доступность LDAP с VM
nc -zv dc01.company.local 389

# Проверить firewall
sudo ufw status

# Разрешить исходящие подключения к LDAP
sudo ufw allow out 389/tcp
sudo ufw allow out 636/tcp
```

### Проблема 4: LDAPS (TLS) ошибки

Для включения LDAPS (порт 636) нужен сертификат CA:

```bash
# Скопировать CA сертификат AD на VM
scp ca-cert.crt root@192.168.9.110:/opt/clickhouse/config/

# В ldap.xml включить TLS
<enable_tls>yes</enable_tls>
<tls_require_cert>demand</tls_require_cert>
<tls_ca_cert_file>/etc/clickhouse-server/config.d/ca-cert.crt</tls_ca_cert_file>
```

---

## Security Best Practices

### 1. Использовать LDAPS вместо LDAP

```xml
<port>636</port>
<enable_tls>yes</enable_tls>
<tls_require_cert>demand</tls_require_cert>
```

### 2. Ограничить bind DN минимальными правами

Служебная учетка `clickhouse-svc` должна иметь права только на:
- Чтение пользователей в `OU=Users`
- Чтение групп в `OU=Groups`

### 3. Регулярно менять пароль служебной учетки

```bash
# В AD сменить пароль для clickhouse-svc
# Обновить ldap.xml на всех нодах
sudo nano /opt/clickhouse/config/ldap.xml
# Перезапустить ClickHouse
docker restart clickhouse-01
```

### 4. Мониторинг LDAP авторизации

```sql
-- Проверить неудачные попытки входа
SELECT
    event_time,
    user,
    client_address,
    exception
FROM system.query_log
WHERE exception LIKE '%Authentication%'
ORDER BY event_time DESC
LIMIT 100;
```

---

## Маппинг ролей по отделам (расширенный)

Если нужно больше гранулярности, создать дополнительные роли:

```sql
-- Финансы (только таблицы finance.*)
CREATE ROLE ROLE_ClickHouse_Finance ON CLUSTER dwh_cluster;
GRANT SELECT ON finance.* TO ROLE_ClickHouse_Finance ON CLUSTER dwh_cluster;

-- HR (только таблицы hr.*)
CREATE ROLE ROLE_ClickHouse_HR ON CLUSTER dwh_cluster;
GRANT SELECT ON hr.* TO ROLE_ClickHouse_HR ON CLUSTER dwh_cluster;

-- Marketing (только таблицы marketing.*)
CREATE ROLE ROLE_ClickHouse_Marketing ON CLUSTER dwh_cluster;
GRANT SELECT ON marketing.* TO ROLE_ClickHouse_Marketing ON CLUSTER dwh_cluster;
```

Создать соответствующие группы в AD:
- `ClickHouse-Finance`
- `ClickHouse-HR`
- `ClickHouse-Marketing`

---

## Полезные ссылки

- [ClickHouse LDAP Authentication](https://clickhouse.com/docs/en/operations/external-authenticators/ldap)
- [RBAC Documentation](https://clickhouse.com/docs/en/guides/sre/user-management/users-and-roles)
- [Active Directory LDAP Syntax](https://learn.microsoft.com/en-us/windows/win32/ad/search-filter-syntax)

---

## Чеклист развертывания

- [ ] Создать служебную учетку `clickhouse-svc` в AD
- [ ] Создать группы безопасности в AD (ClickHouse-Analytics, ClickHouse-Reports)
- [ ] Добавить пользователей в группы AD
- [ ] Создать `/opt/clickhouse/config/ldap.xml` на всех нодах
- [ ] Перезапустить ClickHouse на всех нодах
- [ ] Создать роли в ClickHouse (ROLE_ClickHouse_Analytics, ROLE_ClickHouse_Reports)
- [ ] Протестировать вход доменного пользователя
- [ ] Проверить автоматическое назначение ролей
- [ ] Настроить подключение через DBeaver
- [ ] Настроить мониторинг неудачных попыток входа
