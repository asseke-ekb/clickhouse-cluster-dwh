# Руководство по развертыванию ClickHouse DWH Cluster

## Архитектура

**4 виртуальные машины:**

| VM | IP | Hostname | Компоненты |
|----|-------------|-----------------|------------|
| VM-1 | 192.168.9.110 | DWH-ISS-CH-01 | ClickHouse-01 + ZooKeeper-01 |
| VM-2 | 192.168.9.111 | DWH-ISS-CH-02 | ClickHouse-02 + ZooKeeper-02 |
| VM-3 | 192.168.9.112 | DWH-ISS-CH-03 | ClickHouse-03 + ZooKeeper-03 |
| VM-4 | 192.168.9.113 | DWH-ISS-INFRA-01 | HAProxy + Prometheus + Grafana |

---

## Шаг 1: Настройка /etc/hosts на всех VM

На **ВСЕХ 4 VM** выполнить:

```bash
sudo tee -a /etc/hosts > /dev/null <<EOF
# ClickHouse Cluster
192.168.9.110  clickhouse-01
192.168.9.111  clickhouse-02
192.168.9.112  clickhouse-03

# ZooKeeper Cluster (на тех же VM)
192.168.9.110  zookeeper-01
192.168.9.111  zookeeper-02
192.168.9.112  zookeeper-03

# Infrastructure
192.168.9.113  haproxy prometheus grafana
EOF
```

Проверить:
```bash
cat /etc/hosts
ping clickhouse-01
ping zookeeper-01
ping haproxy
```

---

## Шаг 2: Настройка Firewall

### На VM-1, VM-2, VM-3 (ClickHouse + ZooKeeper):

```bash
# ClickHouse порты
sudo ufw allow from 192.168.9.0/24 to any port 8123 proto tcp   # HTTP API
sudo ufw allow from 192.168.9.0/24 to any port 9000 proto tcp   # Native protocol
sudo ufw allow from 192.168.9.0/24 to any port 9009 proto tcp   # Interserver
sudo ufw allow from 192.168.9.0/24 to any port 9363 proto tcp   # Prometheus metrics

# ZooKeeper порты
sudo ufw allow from 192.168.9.0/24 to any port 2181 proto tcp   # Client
sudo ufw allow from 192.168.9.0/24 to any port 2888 proto tcp   # Peer
sudo ufw allow from 192.168.9.0/24 to any port 3888 proto tcp   # Election

# SSH (замените на ваш IP для безопасности)
sudo ufw allow 22/tcp

sudo ufw enable
sudo ufw status
```

### На VM-4 (Infrastructure):

```bash
# HAProxy endpoints (откройте для клиентов)
sudo ufw allow 8080:8082/tcp  # HTTP endpoints
sudo ufw allow 9090:9091/tcp  # TCP endpoints
sudo ufw allow 8404/tcp       # HAProxy stats

# Мониторинг (ограничьте доступ!)
sudo ufw allow from 192.168.9.0/24 to any port 9099 proto tcp  # Prometheus
sudo ufw allow from 192.168.9.0/24 to any port 3000 proto tcp  # Grafana

# SSH
sudo ufw allow 22/tcp

sudo ufw enable
sudo ufw status
```

---

## Шаг 3: Развертывание VM-1 (192.168.9.110)

```bash
# Создать директории
sudo mkdir -p /data/clickhouse
sudo mkdir -p /data/zookeeper
sudo mkdir -p /var/log/clickhouse
sudo mkdir -p /var/log/zookeeper
sudo mkdir -p /opt/clickhouse/config

# Установить права
sudo chown -R 1000:1000 /data/clickhouse
sudo chown -R 1000:1000 /data/zookeeper
sudo chown -R 1000:1000 /var/log/clickhouse
sudo chown -R 1000:1000 /var/log/zookeeper
```

### Скопировать конфигурационные файлы:

```bash
# На вашем локальном компьютере (из директории проекта)
# Скопировать файлы на VM-1
scp production-deployment/shared-configs/clickhouse-01/config.xml user@192.168.9.110:/tmp/
scp production-deployment/shared-configs/users.xml user@192.168.9.110:/tmp/
scp production-deployment/vm-1-combined/docker-compose.yml user@192.168.9.110:/tmp/

# На VM-1
sudo mv /tmp/config.xml /opt/clickhouse/config/config.xml
sudo mv /tmp/users.xml /opt/clickhouse/config/users.xml

# Создать рабочую директорию
mkdir -p ~/clickhouse-cluster
mv /tmp/docker-compose.yml ~/clickhouse-cluster/

# Запустить контейнеры
cd ~/clickhouse-cluster
docker compose up -d

# Проверить
docker ps
docker logs clickhouse-01
docker logs zookeeper-01

# Проверить ZooKeeper
docker exec zookeeper-01 zkServer.sh status
```

---

## Шаг 4: Развертывание VM-2 (192.168.9.111)

```bash
# Создать директории
sudo mkdir -p /data/clickhouse
sudo mkdir -p /data/zookeeper
sudo mkdir -p /var/log/clickhouse
sudo mkdir -p /var/log/zookeeper
sudo mkdir -p /opt/clickhouse/config

# Установить права
sudo chown -R 1000:1000 /data/clickhouse
sudo chown -R 1000:1000 /data/zookeeper
sudo chown -R 1000:1000 /var/log/clickhouse
sudo chown -R 1000:1000 /var/log/zookeeper
```

### Скопировать конфигурационные файлы:

```bash
# На локальном компьютере
scp production-deployment/shared-configs/clickhouse-02/config.xml user@192.168.9.111:/tmp/
scp production-deployment/shared-configs/users.xml user@192.168.9.111:/tmp/
scp production-deployment/vm-2-combined/docker-compose.yml user@192.168.9.111:/tmp/

# На VM-2
sudo mv /tmp/config.xml /opt/clickhouse/config/config.xml
sudo mv /tmp/users.xml /opt/clickhouse/config/users.xml

mkdir -p ~/clickhouse-cluster
mv /tmp/docker-compose.yml ~/clickhouse-cluster/
cd ~/clickhouse-cluster
docker compose up -d

# Проверить
docker ps
docker logs clickhouse-02
docker logs zookeeper-02
docker exec zookeeper-02 zkServer.sh status
```

---

## Шаг 5: Развертывание VM-3 (192.168.9.112)

```bash
# Создать директории
sudo mkdir -p /data/clickhouse
sudo mkdir -p /data/zookeeper
sudo mkdir -p /var/log/clickhouse
sudo mkdir -p /var/log/zookeeper
sudo mkdir -p /opt/clickhouse/config

# Установить права
sudo chown -R 1000:1000 /data/clickhouse
sudo chown -R 1000:1000 /data/zookeeper
sudo chown -R 1000:1000 /var/log/clickhouse
sudo chown -R 1000:1000 /var/log/zookeeper
```

### Скопировать конфигурационные файлы:

```bash
# На локальном компьютере
scp production-deployment/shared-configs/clickhouse-03/config.xml user@192.168.9.112:/tmp/
scp production-deployment/shared-configs/users.xml user@192.168.9.112:/tmp/
scp production-deployment/vm-3-combined/docker-compose.yml user@192.168.9.112:/tmp/

# На VM-3
sudo mv /tmp/config.xml /opt/clickhouse/config/config.xml
sudo mv /tmp/users.xml /opt/clickhouse/config/users.xml

mkdir -p ~/clickhouse-cluster
mv /tmp/docker-compose.yml ~/clickhouse-cluster/
cd ~/clickhouse-cluster
docker compose up -d

# Проверить
docker ps
docker logs clickhouse-03
docker logs zookeeper-03
docker exec zookeeper-03 zkServer.sh status
```

---

## Шаг 6: Проверка ClickHouse кластера

На **любой из VM-1, VM-2, VM-3**:

```bash
docker exec -it clickhouse-01 clickhouse-client
```

Выполнить SQL:

```sql
-- Проверить кластер (должно быть 3 реплики)
SELECT * FROM system.clusters WHERE cluster = 'dwh_cluster';

-- Проверить ZooKeeper
SELECT * FROM system.zookeeper WHERE path = '/';

-- Создать тестовую таблицу
CREATE TABLE test_replicated ON CLUSTER dwh_cluster
(
    id UInt64,
    name String,
    created DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/test_replicated', '{replica}')
ORDER BY id;

-- Вставить данные на VM-1
INSERT INTO test_replicated (id, name) VALUES (1, 'test from VM-1');

-- Выйти и проверить на VM-2
exit
```

На VM-2:
```bash
docker exec -it clickhouse-02 clickhouse-client --query "SELECT * FROM test_replicated"
```

Должна вернуться запись с VM-1 (репликация работает!)

---

## Шаг 7: Развертывание VM-4 Infrastructure (192.168.9.113)

```bash
# Создать директории
sudo mkdir -p /opt/haproxy
sudo mkdir -p /opt/prometheus
sudo mkdir -p /opt/prometheus/alerts
sudo mkdir -p /data/prometheus
sudo mkdir -p /data/grafana

# Установить права
sudo chown -R 65534:65534 /data/prometheus  # nobody:nogroup для Prometheus
sudo chown -R 472:472 /data/grafana         # grafana user
```

### Скопировать конфигурационные файлы:

```bash
# На локальном компьютере
scp production-deployment/shared-configs/haproxy.cfg user@192.168.9.113:/tmp/
scp production-deployment/shared-configs/prometheus.yml user@192.168.9.113:/tmp/
scp production-deployment/vm-4-infrastructure/docker-compose.yml user@192.168.9.113:/tmp/

# На VM-4
sudo mv /tmp/haproxy.cfg /opt/haproxy/
sudo mv /tmp/prometheus.yml /opt/prometheus/

mkdir -p ~/clickhouse-cluster
mv /tmp/docker-compose.yml ~/clickhouse-cluster/
cd ~/clickhouse-cluster
docker compose up -d

# Проверить
docker ps
docker logs haproxy
docker logs prometheus
docker logs grafana
```

---

## Шаг 8: Проверка HAProxy

### Открыть HAProxy Stats:
```
http://192.168.9.113:8404
```

Все backend серверы должны быть **зелеными (UP)**.

### Тестовые запросы:

```bash
# ETL endpoint (должен попасть на clickhouse-01)
curl "http://192.168.9.113:8080/?query=SELECT getMacro('replica')"
# Ответ: replica_01

# Analytics endpoint (может попасть на любую ноду)
curl "http://192.168.9.113:8081/?query=SELECT getMacro('replica')"

# Reports endpoint (clickhouse-02 или 03)
curl "http://192.168.9.113:8082/?query=SELECT getMacro('replica')"
# Ответ: replica_02 или replica_03
```

---

## Шаг 9: Настройка Grafana

### Открыть Grafana:
```
http://192.168.9.113:3000
```

**Логин:** `admin`
**Пароль:** `admin123`

⚠️ **Сразу смените пароль!**

### Добавить Data Source:

1. Configuration → Data Sources → Add data source
2. Выбрать **Prometheus**
3. URL: `http://localhost:9099`
4. Save & Test

### Импортировать дашборды:

1. Dashboards → Import
2. ClickHouse Overview: ID `14192`
3. ClickHouse Query Analysis: ID `14999`

---

## Шаг 10: Финальная проверка

### Проверка ZooKeeper кластера:

```bash
# На любой из VM-1, VM-2, VM-3
echo ruok | nc 192.168.9.110 2181  # imok
echo ruok | nc 192.168.9.111 2181  # imok
echo ruok | nc 192.168.9.112 2181  # imok

# Проверить статус
docker exec zookeeper-01 zkServer.sh status  # leader или follower
```

### Проверка репликации:

```bash
# На VM-1
docker exec -it clickhouse-01 clickhouse-client --query \
"INSERT INTO test_replicated (id, name) VALUES (2, 'from VM-1')"

# На VM-2
docker exec -it clickhouse-02 clickhouse-client --query \
"SELECT * FROM test_replicated ORDER BY id"

# Должно быть 2 записи
```

### Проверка Prometheus:

Открыть: `http://192.168.9.113:9099`

Status → Targets

Все targets должны быть **UP**:
- clickhouse-01, clickhouse-02, clickhouse-03
- haproxy
- zookeeper (если настроен exporter)

---

## Порты и Endpoints

### ClickHouse (прямой доступ):
- HTTP API: `http://192.168.9.110:8123` (и .111, .112)
- Native TCP: `192.168.9.110:9000` (и .111, .112)
- Metrics: `http://192.168.9.110:9363/metrics`

### HAProxy (Load Balancer):
- ETL HTTP: `http://192.168.9.113:8080` → CH-01
- Analytics HTTP: `http://192.168.9.113:8081` → All nodes
- Reports HTTP: `http://192.168.9.113:8082` → CH-02, CH-03
- ETL TCP: `192.168.9.113:9090` → CH-01
- Analytics TCP: `192.168.9.113:9091` → All nodes
- Stats: `http://192.168.9.113:8404`

### Мониторинг:
- Prometheus: `http://192.168.9.113:9099`
- Grafana: `http://192.168.9.113:3000`

### ZooKeeper:
- Client: `192.168.9.110:2181` (и .111, .112)

---

## Troubleshooting

### Контейнер не стартует:
```bash
docker logs <container-name>
docker exec <container-name> cat /etc/clickhouse-server/config.d/config.xml
```

### ClickHouse не видит ZooKeeper:
```bash
# Проверить доступность
telnet 192.168.9.110 2181
echo ruok | nc 192.168.9.110 2181

# Проверить в ClickHouse
docker exec -it clickhouse-01 clickhouse-client --query \
"SELECT * FROM system.zookeeper WHERE path = '/'"
```

### Репликация не работает:
```sql
-- Проверить очередь
SELECT * FROM system.replication_queue;

-- Проверить статус реплик
SELECT * FROM system.replicas;

-- Принудительно синхронизировать
SYSTEM SYNC REPLICA test_replicated;
```

### HAProxy показывает DOWN:
```bash
# Проверить healthcheck
curl http://192.168.9.110:8123/ping

# Проверить логи HAProxy
docker logs haproxy

# Проверить firewall
sudo ufw status
```

---

## Безопасность

### После развертывания обязательно:

1. ✅ Создать пользователей ClickHouse с паролями
2. ✅ Сменить пароль Grafana
3. ✅ Ограничить доступ к портам через firewall
4. ✅ Настроить SSL/TLS для HAProxy (опционально)
5. ✅ Настроить backup
6. ✅ Включить audit logging

---

## Готово! 🎉

Кластер развернут и готов к работе.

**Подключение через HAProxy:**
```bash
clickhouse-client -h 192.168.9.113 --port 9090
```

**Мониторинг:**
- Grafana: http://192.168.9.113:3000
- HAProxy Stats: http://192.168.9.113:8404
