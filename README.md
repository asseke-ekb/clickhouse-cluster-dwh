# ClickHouse DWH Cluster - Production Setup

Отказоустойчивый кластер ClickHouse для построения корпоративного Data Warehouse с миграцией из MS SQL Server и LDAP аутентификацией.

## 📋 Содержание

1. [Обзор проекта](#обзор-проекта)
2. [Архитектура](#архитектура)
3. [Быстрый старт](#быстрый-старт)
4. [Структура проекта](#структура-проекта)
5. [Документация](#документация)
6. [Миграция данных](#миграция-данных)

---

## Обзор проекта

### Технологический стек

- **ClickHouse 24.3** - Колоночная СУБД для аналитики
- **ZooKeeper 3.8** - Координация и репликация
- **HAProxy 2.8** - Балансировка нагрузки
- **Prometheus + Grafana** - Мониторинг
- **Debezium + Kafka** - CDC для real-time репликации (опционально)

### Ключевые характеристики

- **4 VM** вместо 7 (оптимизация ресурсов)
- **1 шард, 3 реплики** (полная репликация данных)
- **Интеллектуальная балансировка**: ETL, Analytics, Reports endpoints
- **LDAP интеграция**: Доменные учетки для пользователей
- **Миграция из MS SQL**: Готовые скрипты и инструкции

---

## Архитектура

### Топология (4 VM)

```
                    ┌─────────────────────────┐
                    │   HAProxy LB (VM-4)     │
                    │   192.168.9.113         │
                    │   8080-82, 9090-91      │
                    │   + Prometheus:9099     │
                    │   + Grafana:3000        │
                    └────────────┬────────────┘
                                 │
          ┌──────────────────────┼──────────────────────┐
          │                      │                      │
          ▼                      ▼                      ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  VM-1 (110)      │  │  VM-2 (111)      │  │  VM-3 (112)      │
│ ┌──────────────┐ │  │ ┌──────────────┐ │  │ ┌──────────────┐ │
│ │ClickHouse-01 │ │  │ │ClickHouse-02 │ │  │ │ClickHouse-03 │ │
│ │ Write-heavy  │ │  │ │ Read-heavy   │ │  │ │ Read-heavy   │ │
│ └──────┬───────┘ │  │ └──────┬───────┘ │  │ └──────┬───────┘ │
│        │         │  │        │         │  │        │         │
│ ┌──────┴───────┐ │  │ ┌──────┴───────┐ │  │ ┌──────┴───────┐ │
│ │ ZooKeeper-01 │ │  │ │ ZooKeeper-02 │ │  │ │ ZooKeeper-03 │ │
│ └──────────────┘ │  │ └──────────────┘ │  │ └──────────────┘ │
└──────────────────┘  └──────────────────┘  └──────────────────┘
```

### IP Адреса

| VM | IP | Hostname | Компоненты |
|----|-------------|-----------------|------------|
| VM-1 | 192.168.9.110 | DWH-ISS-CH-01 | ClickHouse-01 + ZooKeeper-01 |
| VM-2 | 192.168.9.111 | DWH-ISS-CH-02 | ClickHouse-02 + ZooKeeper-02 |
| VM-3 | 192.168.9.112 | DWH-ISS-CH-03 | ClickHouse-03 + ZooKeeper-03 |
| VM-4 | 192.168.9.113 | DWH-ISS-INFRA-01 | HAProxy + Prometheus + Grafana |

---

## Быстрый старт

### 1. Развертывание кластера

```bash
# См. полную инструкцию
cat production-deployment/DEPLOYMENT_GUIDE.md
```

### 2. Подключение к кластеру

```bash
# Через HAProxy (рекомендуется)
clickhouse-client -h 192.168.9.113 --port 9090 -u admin --password <password>

# Напрямую к ноде
clickhouse-client -h 192.168.9.110 --port 9000 -u admin --password <password>
```

### 3. Проверка статуса

```sql
-- Проверить все ноды кластера
SELECT hostName(), version() FROM cluster('dwh_cluster', system.one);

-- Проверить репликацию
SELECT * FROM system.replicas;
```

### 4. Создание первой таблицы

```sql
-- Пример реплицируемой таблицы
CREATE TABLE test.events ON CLUSTER dwh_cluster
(
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    event_type String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/test/events', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);
```

---

## Структура проекта

```
clickhouse-cluster-dwh/
├── README.md                           # Этот файл
├── CLUSTER_DOCUMENTATION.md            # Полная техническая документация
│
├── production-deployment/              # Конфигурации для развертывания
│   ├── DEPLOYMENT_GUIDE.md             # Пошаговая инструкция развертывания
│   ├── LDAP_SETUP.md                   # Настройка LDAP интеграции
│   │
│   ├── vm-1-combined/                  # ClickHouse-01 + ZooKeeper-01
│   │   └── docker-compose.yml
│   ├── vm-2-combined/                  # ClickHouse-02 + ZooKeeper-02
│   │   └── docker-compose.yml
│   ├── vm-3-combined/                  # ClickHouse-03 + ZooKeeper-03
│   │   └── docker-compose.yml
│   ├── vm-4-infrastructure/            # HAProxy + Prometheus + Grafana
│   │   └── docker-compose.yml
│   │
│   └── shared-configs/                 # Общие конфигурации
│       ├── clickhouse-01/config.xml    # Write-optimized
│       ├── clickhouse-02/config.xml    # Read-optimized
│       ├── clickhouse-03/config.xml    # Read-optimized
│       ├── users.xml.example           # Шаблон пользователей
│       ├── haproxy.cfg                 # Балансировщик нагрузки
│       ├── prometheus.yml              # Метрики
│       ├── ldap.xml.example            # LDAP конфигурация
│       └── ldap-roles.sql              # SQL роли для LDAP
│
└── migration/                          # Миграция из MS SQL
    ├── README.md                       # Документация миграции
    ├── person_final_production.sql     # Финальная таблица person
    ├── CDC_KAFKA_SETUP.md              # Real-time CDC через Kafka
    └── fix_person_metadata_conflict.sql # Troubleshooting
```

---

## Документация

### Основная документация

- **[CLUSTER_DOCUMENTATION.md](CLUSTER_DOCUMENTATION.md)** - Полная техническая документация кластера
  - Архитектура и топология
  - Балансировка нагрузки (ETL, Analytics, Reports)
  - RBAC и управление пользователями
  - Мониторинг и оптимизация
  - Резервное копирование
  - Troubleshooting

### Развертывание

- **[DEPLOYMENT_GUIDE.md](production-deployment/DEPLOYMENT_GUIDE.md)** - Пошаговая инструкция развертывания
  - Подготовка VM
  - Установка Docker
  - Конфигурация ClickHouse и ZooKeeper
  - Настройка HAProxy
  - Проверка работоспособности

### LDAP интеграция

- **[LDAP_SETUP.md](production-deployment/LDAP_SETUP.md)** - Настройка доменной аутентификации
  - Подключение к Active Directory
  - Маппинг групп AD → роли ClickHouse
  - Роли для аналитиков и отчетов
  - Настройка DBeaver с LDAP

### Миграция данных

- **[migration/README.md](migration/README.md)** - Миграция из MS SQL Server
  - Структура таблицы person
  - Экспорт данных из MS SQL
  - Импорт в ClickHouse
  - Pentaho Data Integration
  - CDC через Kafka

---

## Миграция данных

### Из MS SQL Server

```bash
# См. полную документацию
cat migration/README.md
```

**Готовые скрипты**:
- `migration/person_final_production.sql` - Таблица person для миграции
- `migration/CDC_KAFKA_SETUP.md` - Real-time CDC через Kafka + Debezium

**Пример таблицы**: `rpmu.person` (21 поле, ~5M строк)

### Pentaho Data Integration (PDI)

Настроенный маппинг полей MS SQL → ClickHouse:
- UUID → String (36 символов)
- DateTime → DateTime64(3)
- bit → UInt8
- Nullable поля корректно обрабатываются

---

## Балансировка нагрузки

### HAProxy Endpoints

| Endpoint | Порт | Назначение | Стратегия |
|----------|------|------------|-----------|
| **ETL** | 8080 (HTTP), 9090 (TCP) | Массовые INSERT | Только CH-01 |
| **Analytics** | 8081 (HTTP), 9091 (TCP) | Быстрые SELECT | Все ноды (leastconn) |
| **Reports** | 8082 (HTTP) | Тяжелые отчеты | CH-02/03 (source hash) |
| **Stats** | 8404 | HAProxy статистика | - |

### Примеры использования

```bash
# ETL процессы (вставка данных)
clickhouse-client -h 192.168.9.113 --port 9090 --query "INSERT INTO ..."

# Аналитические запросы
clickhouse-client -h 192.168.9.113 --port 9091 --query "SELECT ..."

# Проверка статуса HAProxy
curl http://192.168.9.113:8404
```

---

## LDAP Аутентификация

### Быстрая настройка

1. Создать группы в Active Directory:
   - `ClickHouse-Analytics` - для аналитиков
   - `ClickHouse-Reports` - для отчетов
   - `ClickHouse-Admins` - для администраторов

2. Настроить LDAP в ClickHouse:
   ```bash
   # См. подробную инструкцию
   cat production-deployment/LDAP_SETUP.md
   ```

3. Пользователи входят с доменными учетками:
   ```bash
   clickhouse-client -h 192.168.9.113 --port 9090 \
     -u "DOMAIN\username" --password "ad_password"
   ```

### Автоматический маппинг ролей

| AD группа | ClickHouse роль | Права |
|-----------|-----------------|-------|
| ClickHouse-Analytics | ROLE_ClickHouse_Analytics | SELECT, 10GB RAM, 5 мин |
| ClickHouse-Reports | ROLE_ClickHouse_Reports | SELECT + VIEW, 30GB RAM, 30 мин |
| ClickHouse-Admins | ROLE_ClickHouse_Admins | ALL + ACCESS MANAGEMENT |

---

## Мониторинг

### Grafana Dashboards

**URL**: http://192.168.9.113:3000
**Login**: `admin` / `admin123`

Импортировать дашборды:
- ClickHouse Overview (ID: 14192)
- ClickHouse Query Analysis (ID: 14999)
- HAProxy (ID: 12693)

### Prometheus Metrics

**URL**: http://192.168.9.113:9099

Ключевые метрики:
- `ClickHouseProfileEvents_Query` - Запросов в секунду
- `ClickHouseMetrics_MemoryTracking` - Использование памяти
- `ClickHouseMetrics_ReplicationQueue` - Очередь репликации

---

## Производительность

### Текущая конфигурация (16-32 cores, 64-128 GB RAM)

| Операция | Производительность |
|----------|-------------------|
| INSERT (batch) | 2-5M строк/сек |
| SELECT (простые) | <100ms |
| SELECT (сложные) | 1-10 сек |
| JOIN (small) | <1 сек |
| Параллельные запросы | 300-500 |

### Объем данных

- Текущие данные: ~5B записей = 2.4 TB (с репликацией ×3)
- Прирост: 1.5M-8M строк/день
- Retention: 2-3 года на 2 TB дисках

---

## Резервное копирование

### Стратегия

```sql
-- Полный бэкап базы данных
BACKUP DATABASE rpmu TO Disk('backups', 'backup_2025_10_06.zip');

-- Восстановление
RESTORE DATABASE rpmu FROM Disk('backups', 'backup_2025_10_06.zip');
```

### Автоматизация (cron)

```bash
# Ежедневный бэкап в 2:00
0 2 * * * /opt/scripts/clickhouse_backup.sh
```

---

## Troubleshooting

### Частые проблемы

1. **METADATA_MISMATCH** при создании таблицы
   ```bash
   # Решение в migration/fix_person_metadata_conflict.sql
   ```

2. **Реплики не синхронизируются**
   ```sql
   SYSTEM SYNC REPLICA table_name;
   ```

3. **ZooKeeper недоступен**
   ```bash
   docker restart zookeeper-01
   ```

4. **HAProxy backend DOWN**
   ```bash
   # Проверить health check
   curl http://192.168.9.110:8123/ping
   ```

---

## Полезные ссылки

**Документация**:
- [ClickHouse Official Docs](https://clickhouse.com/docs)
- [HAProxy Documentation](https://www.haproxy.org/)
- [ZooKeeper Guide](https://zookeeper.apache.org/)

**Мониторинг**:
- HAProxy Stats: http://192.168.9.113:8404
- Grafana: http://192.168.9.113:3000
- Prometheus: http://192.168.9.113:9099

---

## Changelog

| Версия | Дата | Изменения |
|--------|------|-----------|
| 1.0 | 2025-10-01 | Начальное развертывание (7 VM) |
| 2.0 | 2025-10-06 | Консолидация в 4 VM + LDAP + миграция person |

---

## Контакты

**Администратор кластера**: DWH Team
**Кластер**: dwh_cluster (192.168.9.110-113)
