# Production Deployment - ClickHouse DWH Cluster

Этот каталог содержит конфигурации для развертывания ClickHouse кластера на отдельных виртуальных машинах (Вариант 3 - Production).

## Структура каталога

```
production-deployment/
├── vm-1-clickhouse-01/          # ClickHouse Node-01 (Write-optimized)
│   └── docker-compose.yml
├── vm-2-clickhouse-02/          # ClickHouse Node-02 (Read-optimized)
│   └── docker-compose.yml
├── vm-3-clickhouse-03/          # ClickHouse Node-03 (Read-optimized)
│   └── docker-compose.yml
├── vm-4-zookeeper-01/           # ZooKeeper Node-01
│   └── docker-compose.yml
├── vm-5-zookeeper-02/           # ZooKeeper Node-02
│   └── docker-compose.yml
├── vm-6-zookeeper-03/           # ZooKeeper Node-03
│   └── docker-compose.yml
├── vm-7-infrastructure/         # HAProxy + Prometheus + Grafana
│   └── docker-compose.yml
├── shared-configs/              # Конфигурационные файлы (для копирования на VM)
│   ├── clickhouse-01/
│   ├── clickhouse-02/
│   ├── clickhouse-03/
│   ├── users.xml
│   ├── haproxy.cfg
│   └── prometheus.yml
└── README.md                    # Этот файл
```

## Требования к инфраструктуре

### Виртуальные машины

| VM | Роль | CPU | RAM | Disk | IP |
|----|------|-----|-----|------|-----|
| VM-1 | ClickHouse-01 (Write) | 8-32 cores | 16-128 GB | 2-4 TB NVMe | `<заполнить>` |
| VM-2 | ClickHouse-02 (Read) | 8-32 cores | 16-128 GB | 2-4 TB NVMe | `<заполнить>` |
| VM-3 | ClickHouse-03 (Read) | 8-32 cores | 16-128 GB | 2-4 TB NVMe | `<заполнить>` |
| VM-4 | ZooKeeper-01 | 4 cores | 8 GB | 100 GB SSD | `<заполнить>` |
| VM-5 | ZooKeeper-02 | 4 cores | 8 GB | 100 GB SSD | `<заполнить>` |
| VM-6 | ZooKeeper-03 | 4 cores | 8 GB | 100 GB SSD | `<заполнить>` |
| VM-7 | Infrastructure | 4-8 cores | 16 GB | 200 GB SSD | `<заполнить>` |

### Операционная система
- Ubuntu 22.04 LTS или RHEL 8+ на всех VM

## Пошаговое развертывание

### Шаг 1: Подготовка всех VM

Выполнить на **каждой из 7 VM**:

#### 1.1 Обновить систему
```bash
sudo apt-get update && sudo apt-get upgrade -y
```

#### 1.2 Установить Docker и Docker Compose
```bash
# Добавить Docker GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Добавить репозиторий
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Установить Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Добавить текущего пользователя в группу docker
sudo usermod -aG docker $USER

# Перелогиниться для применения изменений группы
```

#### 1.3 Настроить /etc/hosts

На **всех 7 VM** добавить записи DNS (заменить `<VM-X-IP>` на реальные IP):

```bash
sudo tee -a /etc/hosts > /dev/null <<EOF
# ClickHouse Nodes
<VM-1-IP>  clickhouse-01
<VM-2-IP>  clickhouse-02
<VM-3-IP>  clickhouse-03

# ZooKeeper Nodes
<VM-4-IP>  zookeeper-01
<VM-5-IP>  zookeeper-02
<VM-6-IP>  zookeeper-03

# HAProxy + Monitoring
<VM-7-IP>  haproxy prometheus grafana
EOF
```

#### 1.4 Настроить Firewall

**На VM-1, VM-2, VM-3 (ClickHouse)**:
```bash
sudo ufw allow 8123/tcp   # HTTP API
sudo ufw allow 9000/tcp   # Native protocol
sudo ufw allow 9009/tcp   # Interserver
sudo ufw allow 9363/tcp   # Prometheus metrics
sudo ufw allow 22/tcp     # SSH
sudo ufw enable
```

**На VM-4, VM-5, VM-6 (ZooKeeper)**:
```bash
sudo ufw allow 2181/tcp   # Client
sudo ufw allow 2888/tcp   # Peer
sudo ufw allow 3888/tcp   # Election
sudo ufw allow 22/tcp     # SSH
sudo ufw enable
```

**На VM-7 (Infrastructure)**:
```bash
sudo ufw allow 8080:8082/tcp  # HAProxy HTTP frontends
sudo ufw allow 8404/tcp       # HAProxy stats
sudo ufw allow 9090:9091/tcp  # HAProxy TCP frontends
sudo ufw allow 9099/tcp       # Prometheus
sudo ufw allow 3000/tcp       # Grafana
sudo ufw allow 22/tcp         # SSH
sudo ufw enable
```

---

### Шаг 2: Подготовка конфигурационных файлов

#### 2.1 Обновить IP адреса в docker-compose файлах

**VM-4, VM-5, VM-6 (ZooKeeper)**:

Отредактировать `docker-compose.yml` в каждой директории и заменить `<VM-X-IP>` на реальные IP адреса:

```bash
# Пример для vm-4-zookeeper-01/docker-compose.yml
ZOO_SERVERS: server.1=0.0.0.0:2888:3888;2181 server.2=<VM-5-IP>:2888:3888;2181 server.3=<VM-6-IP>:2888:3888;2181
```

#### 2.2 Обновить конфигурацию ClickHouse

В файлах `shared-configs/clickhouse-0X/config.xml` проверить, что hostnames ZooKeeper указаны корректно:

```xml
<zookeeper>
    <node>
        <host>zookeeper-01</host>  <!-- Должно резолвиться через /etc/hosts -->
        <port>2181</port>
    </node>
    <!-- ... -->
</zookeeper>
```

Аналогично для `<remote_servers>`:
```xml
<remote_servers>
    <dwh_cluster>
        <shard>
            <replica>
                <host>clickhouse-01</host>  <!-- Должно резолвиться через /etc/hosts -->
                <port>9000</port>
            </replica>
            <!-- ... -->
        </shard>
    </dwh_cluster>
</remote_servers>
```

#### 2.3 Обновить конфигурацию HAProxy

В `shared-configs/haproxy.cfg` hostnames должны резолвиться:

```cfg
backend clickhouse_etl_http
    # ...
    server clickhouse-01 clickhouse-01:8123 check  # Резолвится через /etc/hosts
    server clickhouse-02 clickhouse-02:8123 check
    server clickhouse-03 clickhouse-03:8123 check
```

#### 2.4 Обновить конфигурацию Prometheus

В `shared-configs/prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'clickhouse-01'
    static_configs:
      - targets: ['clickhouse-01:9363']  # Резолвится через /etc/hosts
```

---

### Шаг 3: Развертывание на VM

#### 3.1 Развертывание ZooKeeper Nodes (VM-4, VM-5, VM-6)

На **VM-4** (zookeeper-01):
```bash
# Создать директории
sudo mkdir -p /data/zookeeper
sudo mkdir -p /var/log/zookeeper

# Скопировать docker-compose.yml
mkdir -p ~/clickhouse-cluster
cd ~/clickhouse-cluster
# Скопировать содержимое vm-4-zookeeper-01/docker-compose.yml

# Запустить
docker compose up -d

# Проверить
docker ps
docker logs zookeeper-01
```

Повторить аналогично на **VM-5** и **VM-6** с соответствующими файлами.

Проверить статус кластера ZooKeeper:
```bash
docker exec zookeeper-01 zkServer.sh status
# Должно показать "Mode: leader" или "Mode: follower"
```

---

#### 3.2 Развертывание ClickHouse Nodes (VM-1, VM-2, VM-3)

На **VM-1** (clickhouse-01):
```bash
# Создать директории
sudo mkdir -p /data/clickhouse
sudo mkdir -p /var/log/clickhouse
sudo mkdir -p /opt/clickhouse/config

# Скопировать конфигурационные файлы
# Скопировать shared-configs/clickhouse-01/config.xml в /opt/clickhouse/config/config.xml
# Скопировать shared-configs/users.xml в /opt/clickhouse/config/users.xml

# Скопировать docker-compose.yml
mkdir -p ~/clickhouse-cluster
cd ~/clickhouse-cluster
# Скопировать содержимое vm-1-clickhouse-01/docker-compose.yml

# Запустить
docker compose up -d

# Проверить
docker ps
docker logs clickhouse-01
```

Повторить на **VM-2** (clickhouse-02) и **VM-3** (clickhouse-03) с соответствующими конфигами.

---

#### 3.3 Проверка кластера ClickHouse

Подключиться к любой ноде:
```bash
docker exec -it clickhouse-01 clickhouse-client
```

Проверить кластер:
```sql
-- Должны быть видны все 3 реплики
SELECT * FROM system.clusters WHERE cluster = 'dwh_cluster';

-- Проверить репликацию
SELECT
    database,
    table,
    is_leader,
    total_replicas,
    active_replicas
FROM system.replicas;

-- Проверить ZooKeeper
SELECT * FROM system.zookeeper WHERE path = '/';
```

---

#### 3.4 Развертывание Infrastructure (VM-7)

На **VM-7**:
```bash
# Создать директории
sudo mkdir -p /opt/haproxy
sudo mkdir -p /opt/prometheus
sudo mkdir -p /opt/prometheus/alerts
sudo mkdir -p /opt/grafana/provisioning

# Скопировать конфигурационные файлы
# Скопировать shared-configs/haproxy.cfg в /opt/haproxy/haproxy.cfg
# Скопировать shared-configs/prometheus.yml в /opt/prometheus/prometheus.yml

# Скопировать docker-compose.yml
mkdir -p ~/clickhouse-cluster
cd ~/clickhouse-cluster
# Скопировать содержимое vm-7-infrastructure/docker-compose.yml

# Запустить
docker compose up -d

# Проверить
docker ps
```

---

### Шаг 4: Проверка всего кластера

#### 4.1 Проверить HAProxy

Открыть в браузере: `http://<VM-7-IP>:8404`

Должна открыться страница статистики HAProxy. Все backend серверы должны быть зелеными (UP).

#### 4.2 Тестовый запрос через HAProxy

```bash
# ETL endpoint (должен попасть на clickhouse-01)
curl "http://<VM-7-IP>:8080/?query=SELECT getMacro('replica')"
# Должен вернуть: replica_01

# Analytics endpoint (может попасть на любую ноду)
curl "http://<VM-7-IP>:8081/?query=SELECT getMacro('replica')"

# Reports endpoint (должен попасть на clickhouse-02 или clickhouse-03)
curl "http://<VM-7-IP>:8082/?query=SELECT getMacro('replica')"
# Должен вернуть: replica_02 или replica_03
```

#### 4.3 Проверить Prometheus

Открыть: `http://<VM-7-IP>:9099`

Проверить targets: Status → Targets
Все targets должны быть UP.

#### 4.4 Проверить Grafana

Открыть: `http://<VM-7-IP>:3000`

Login: `admin` / `admin123`

⚠️ **Сразу после первого входа измените пароль!**

Импортировать дашборды:
- ClickHouse Overview: ID `14192`
- ClickHouse Query Analysis: ID `14999`

---

### Шаг 5: Создание пользователей через RBAC

Подключиться к кластеру как admin:

```bash
# Через HAProxy (TCP endpoint)
clickhouse-client -h <VM-7-IP> --port 9090 --user admin --password admin_super_secure_2024
```

Создать роли и пользователей (см. документацию в CLUSTER_DOCUMENTATION.md, раздел "Управление пользователями и RBAC"):

```sql
-- Создать роли
CREATE ROLE etl_role ON CLUSTER dwh_cluster;
CREATE ROLE analytics_role ON CLUSTER dwh_cluster;
CREATE ROLE reports_role ON CLUSTER dwh_cluster;

-- Назначить права
GRANT CREATE TABLE, INSERT, SELECT ON *.* TO etl_role;
GRANT SELECT ON *.* TO analytics_role;
GRANT SELECT, CREATE TEMPORARY TABLE ON *.* TO reports_role;

-- Создать пользователей
CREATE USER etl_user ON CLUSTER dwh_cluster
IDENTIFIED WITH sha256_password BY 'strong_password_here';
GRANT etl_role TO etl_user ON CLUSTER dwh_cluster;

-- Аналогично для analytics_user и reports_user
```

---

## Эксплуатация

### Запуск/остановка сервисов

На каждой VM:
```bash
cd ~/clickhouse-cluster

# Запуск
docker compose up -d

# Остановка
docker compose down

# Перезапуск
docker compose restart

# Просмотр логов
docker compose logs -f
```

### Мониторинг

**Логи ClickHouse**:
```bash
# На VM-1, VM-2, VM-3
tail -f /var/log/clickhouse/clickhouse-server.log
tail -f /var/log/clickhouse/clickhouse-server.err.log
```

**Логи ZooKeeper**:
```bash
# На VM-4, VM-5, VM-6
tail -f /var/log/zookeeper/zookeeper.log
```

**Метрики**:
- Grafana: `http://<VM-7-IP>:3000`
- Prometheus: `http://<VM-7-IP>:9099`
- HAProxy Stats: `http://<VM-7-IP>:8404`

### Backup

Создать скрипт на VM-7 или отдельной backup-машине:

```bash
#!/bin/bash
# /opt/scripts/clickhouse_backup.sh

DATE=$(date +%Y_%m_%d)
BACKUP_NAME="backup_${DATE}"

clickhouse-client -h <VM-7-IP> --port 9090 --user admin --password admin_super_secure_2024 --query \
"BACKUP DATABASE dwh TO Disk('backups', '${BACKUP_NAME}.zip')"

# Удалить бэкапы старше 7 дней
find /backups -name "backup_*.zip" -mtime +7 -delete
```

Добавить в crontab:
```bash
0 2 * * * /opt/scripts/clickhouse_backup.sh
```

---

## Troubleshooting

### Проблема: Контейнер не стартует

```bash
# Проверить логи
docker logs <container-name>

# Проверить конфигурацию
docker exec <container-name> cat /etc/clickhouse-server/config.d/config.xml

# Проверить сеть
ping clickhouse-01
ping zookeeper-01
```

### Проблема: Реплики не синхронизируются

```sql
-- Проверить очередь репликации
SELECT * FROM system.replication_queue;

-- Принудительно синхронизировать
SYSTEM SYNC REPLICA table_name;
```

### Проблема: ZooKeeper недоступен

```bash
# Проверить статус
docker exec zookeeper-01 zkServer.sh status

# Проверить подключение
echo ruok | nc zookeeper-01 2181
# Должно вернуть: imok
```

### Проблема: HAProxy показывает backend DOWN

```bash
# Проверить health check
curl http://clickhouse-01:8123/ping

# Проверить логи HAProxy
docker logs haproxy

# Проверить firewall
sudo ufw status
```

---

## Безопасность

### Чеклист после развертывания

- [ ] Изменить пароль `admin` пользователя ClickHouse
- [ ] Изменить пароль Grafana (admin/admin123)
- [ ] Настроить SSL/TLS для HAProxy (опционально)
- [ ] Ограничить доступ к VM по IP (firewall rules)
- [ ] Настроить VPN или bastion host для доступа
- [ ] Включить аудит логов (auditd)
- [ ] Настроить автоматические обновления безопасности

---

## Ссылки

- Полная документация: [../CLUSTER_DOCUMENTATION.md](../CLUSTER_DOCUMENTATION.md)
- ClickHouse документация: https://clickhouse.com/docs
- HAProxy документация: https://www.haproxy.org/
- Prometheus документация: https://prometheus.io/docs/

---

## Поддержка

При возникновении проблем:
1. Проверить раздел Troubleshooting выше
2. Проверить логи сервисов
3. Обратиться к CLUSTER_DOCUMENTATION.md
4. Открыть issue в репозитории проекта
