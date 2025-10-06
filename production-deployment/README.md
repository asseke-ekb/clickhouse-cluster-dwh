# Production Deployment - ClickHouse DWH Cluster

Этот каталог содержит конфигурации для развертывания ClickHouse кластера на 3 виртуальных машинах. На каждой VM запускается 1 нода ClickHouse и 1 нода ZooKeeper.

## Структура каталога

```
production-deployment/
├── vm-1-combined/               # ClickHouse-01 + ZooKeeper-01
│   └── docker-compose.yml
├── vm-2-combined/               # ClickHouse-02 + ZooKeeper-02
│   └── docker-compose.yml
├── vm-3-combined/               # ClickHouse-03 + ZooKeeper-03
│   └── docker-compose.yml
├── shared-configs/              # Конфигурационные файлы (для копирования на VM)
│   ├── clickhouse-01/
│   │   └── config.xml
│   ├── clickhouse-02/
│   │   └── config.xml
│   ├── clickhouse-03/
│   │   └── config.xml
│   └── users.xml
└── README.md                    # Этот файл
```

## Требования к инфраструктуре

### Виртуальные машины

| VM | Компоненты | CPU | RAM | Disk | IP |
|----|-----------|-----|-----|------|-----|
| VM-1 | ClickHouse-01 + ZooKeeper-01 | 8-32 cores | 16-128 GB | 2-4 TB NVMe | `<заполнить>` |
| VM-2 | ClickHouse-02 + ZooKeeper-02 | 8-32 cores | 16-128 GB | 2-4 TB NVMe | `<заполнить>` |
| VM-3 | ClickHouse-03 + ZooKeeper-03 | 8-32 cores | 16-128 GB | 2-4 TB NVMe | `<заполнить>` |

**Примечание**: На каждой VM будет запущено 2 контейнера:
- 1 контейнер ClickHouse (основное потребление ресурсов)
- 1 контейнер ZooKeeper (легковесный, ~2-4 GB RAM)

### Операционная система
- Ubuntu 22.04 LTS или RHEL 8+ на всех VM

## Пошаговое развертывание

### Шаг 1: Подготовка всех VM

Выполнить на **каждой из 3 VM**:

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

На **всех 3 VM** добавить записи DNS (заменить `<VM-X-IP>` на реальные IP):

```bash
sudo tee -a /etc/hosts > /dev/null <<EOF
# ClickHouse Nodes
<VM-1-IP>  clickhouse-01
<VM-2-IP>  clickhouse-02
<VM-3-IP>  clickhouse-03

# ZooKeeper Nodes (на тех же VM)
<VM-1-IP>  zookeeper-01
<VM-2-IP>  zookeeper-02
<VM-3-IP>  zookeeper-03
EOF
```

#### 1.4 Настроить Firewall

**На всех 3 VM**:
```bash
# ClickHouse порты
sudo ufw allow 8123/tcp   # HTTP API
sudo ufw allow 9000/tcp   # Native protocol
sudo ufw allow 9009/tcp   # Interserver
sudo ufw allow 9363/tcp   # Prometheus metrics

# ZooKeeper порты
sudo ufw allow 2181/tcp   # Client
sudo ufw allow 2888/tcp   # Peer
sudo ufw allow 3888/tcp   # Election

# SSH
sudo ufw allow 22/tcp
sudo ufw enable
```

---

### Шаг 2: Подготовка конфигурационных файлов

#### 2.1 Обновить IP адреса в docker-compose файлах

**На всех VM**:

Отредактировать `docker-compose.yml` в каждой директории и заменить `<VM-X-IP>` на реальные IP адреса:

```bash
# Пример для vm-1-combined/docker-compose.yml
ZOO_SERVERS: server.1=0.0.0.0:2888:3888;2181 server.2=<VM-2-IP>:2888:3888;2181 server.3=<VM-3-IP>:2888:3888;2181

# Для vm-2-combined/docker-compose.yml
ZOO_SERVERS: server.1=<VM-1-IP>:2888:3888;2181 server.2=0.0.0.0:2888:3888;2181 server.3=<VM-3-IP>:2888:3888;2181

# Для vm-3-combined/docker-compose.yml
ZOO_SERVERS: server.1=<VM-1-IP>:2888:3888;2181 server.2=<VM-2-IP>:2888:3888;2181 server.3=0.0.0.0:2888:3888;2181
```

#### 2.2 Проверить конфигурацию ClickHouse

В файлах `shared-configs/clickhouse-0X/config.xml` проверить, что hostnames ZooKeeper указаны корректно:

```xml
<zookeeper>
    <node>
        <host>zookeeper-01</host>  <!-- Должно резолвиться через /etc/hosts -->
        <port>2181</port>
    </node>
    <node>
        <host>zookeeper-02</host>
        <port>2181</port>
    </node>
    <node>
        <host>zookeeper-03</host>
        <port>2181</port>
    </node>
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
            <replica>
                <host>clickhouse-02</host>
                <port>9000</port>
            </replica>
            <replica>
                <host>clickhouse-03</host>
                <port>9000</port>
            </replica>
        </shard>
    </dwh_cluster>
</remote_servers>
```

---

### Шаг 3: Развертывание на VM

#### 3.1 Развертывание на VM-1

На **VM-1**:
```bash
# Создать директории для ClickHouse
sudo mkdir -p /data/clickhouse
sudo mkdir -p /var/log/clickhouse
sudo mkdir -p /opt/clickhouse/config

# Создать директории для ZooKeeper
sudo mkdir -p /data/zookeeper
sudo mkdir -p /var/log/zookeeper

# Скопировать конфигурационные файлы ClickHouse
# Скопировать shared-configs/clickhouse-01/config.xml в /opt/clickhouse/config/config.xml
# Скопировать shared-configs/users.xml в /opt/clickhouse/config/users.xml

# Скопировать docker-compose.yml
mkdir -p ~/clickhouse-cluster
cd ~/clickhouse-cluster
# Скопировать содержимое vm-1-combined/docker-compose.yml

# Запустить оба контейнера
docker compose up -d

# Проверить
docker ps
docker logs clickhouse-01
docker logs zookeeper-01
```

#### 3.2 Развертывание на VM-2

На **VM-2**:
```bash
# Создать директории для ClickHouse
sudo mkdir -p /data/clickhouse
sudo mkdir -p /var/log/clickhouse
sudo mkdir -p /opt/clickhouse/config

# Создать директории для ZooKeeper
sudo mkdir -p /data/zookeeper
sudo mkdir -p /var/log/zookeeper

# Скопировать конфигурационные файлы ClickHouse
# Скопировать shared-configs/clickhouse-02/config.xml в /opt/clickhouse/config/config.xml
# Скопировать shared-configs/users.xml в /opt/clickhouse/config/users.xml

# Скопировать docker-compose.yml
mkdir -p ~/clickhouse-cluster
cd ~/clickhouse-cluster
# Скопировать содержимое vm-2-combined/docker-compose.yml

# Запустить оба контейнера
docker compose up -d

# Проверить
docker ps
docker logs clickhouse-02
docker logs zookeeper-02
```

#### 3.3 Развертывание на VM-3

На **VM-3**:
```bash
# Создать директории для ClickHouse
sudo mkdir -p /data/clickhouse
sudo mkdir -p /var/log/clickhouse
sudo mkdir -p /opt/clickhouse/config

# Создать директории для ZooKeeper
sudo mkdir -p /data/zookeeper
sudo mkdir -p /var/log/zookeeper

# Скопировать конфигурационные файлы ClickHouse
# Скопировать shared-configs/clickhouse-03/config.xml в /opt/clickhouse/config/config.xml
# Скопировать shared-configs/users.xml в /opt/clickhouse/config/users.xml

# Скопировать docker-compose.yml
mkdir -p ~/clickhouse-cluster
cd ~/clickhouse-cluster
# Скопировать содержимое vm-3-combined/docker-compose.yml

# Запустить оба контейнера
docker compose up -d

# Проверить
docker ps
docker logs clickhouse-03
docker logs zookeeper-03
```

---

### Шаг 4: Проверка кластера

#### 4.1 Проверка ZooKeeper кластера

На любой VM:
```bash
docker exec zookeeper-01 zkServer.sh status
# Должно показать "Mode: leader" или "Mode: follower"

# Проверить подключение ко всем нодам
echo ruok | nc zookeeper-01 2181  # Должно вернуть: imok
echo ruok | nc zookeeper-02 2181
echo ruok | nc zookeeper-03 2181
```

#### 4.2 Проверка ClickHouse кластера

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

#### 4.3 Тестовая таблица

Создать тестовую реплицированную таблицу:
```sql
-- На любой ноде
CREATE TABLE test_replicated ON CLUSTER dwh_cluster
(
    id UInt64,
    name String,
    created DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/test_replicated', '{replica}')
ORDER BY id;

-- Вставить данные на одной ноде
INSERT INTO test_replicated (id, name) VALUES (1, 'test');

-- Проверить на других нодах
SELECT * FROM test_replicated;
```

---

## Эксплуатация

### Запуск/остановка сервисов

На каждой VM:
```bash
cd ~/clickhouse-cluster

# Запуск всех контейнеров
docker compose up -d

# Остановка всех контейнеров
docker compose down

# Перезапуск
docker compose restart

# Просмотр логов
docker compose logs -f
docker compose logs -f clickhouse-01
docker compose logs -f zookeeper-01
```

### Мониторинг

**Логи ClickHouse**:
```bash
tail -f /var/log/clickhouse/clickhouse-server.log
tail -f /var/log/clickhouse/clickhouse-server.err.log
```

**Логи ZooKeeper**:
```bash
tail -f /var/log/zookeeper/zookeeper.log
```

**Метрики ClickHouse**:
```bash
# Prometheus endpoint
curl http://localhost:9363/metrics
```

### Backup

Создать скрипт на одной из VM:

```bash
#!/bin/bash
# /opt/scripts/clickhouse_backup.sh

DATE=$(date +%Y_%m_%d)
BACKUP_NAME="backup_${DATE}"

clickhouse-client --query \
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

### Проблема: Порты заняты

Так как используется `network_mode: host`, убедитесь что на VM не запущены другие сервисы на портах:
- ClickHouse: 8123, 9000, 9009, 9363
- ZooKeeper: 2181, 2888, 3888

```bash
# Проверить занятые порты
sudo netstat -tulpn | grep -E '8123|9000|2181|2888|3888'
```

---

## Безопасность

### Чеклист после развертывания

- [ ] Изменить пароль `admin` пользователя ClickHouse
- [ ] Ограничить доступ к VM по IP (firewall rules)
- [ ] Настроить VPN или bastion host для доступа
- [ ] Включить аудит логов (auditd)
- [ ] Настроить автоматические обновления безопасности
- [ ] Регулярно обновлять Docker images

---

## Преимущества данной архитектуры

1. **Упрощенная инфраструктура**: Всего 3 VM вместо 6-7
2. **Снижение затрат**: Меньше виртуальных машин = меньше расходов
3. **Локальность**: ClickHouse и ZooKeeper на одной машине = меньше сетевой латенси
4. **Простота управления**: Меньше точек отказа и проще мониторинг

## Недостатки

1. **Совместное использование ресурсов**: ClickHouse и ZooKeeper конкурируют за CPU/RAM
2. **Высокая нагрузка на VM**: Каждая VM несет двойную нагрузку
3. **Риск каскадных отказов**: Если VM падает, теряется и ClickHouse и ZooKeeper нода

**Рекомендация**: Эта архитектура подходит для средних нагрузок. Для высоконагруженных систем рассмотрите разделение ClickHouse и ZooKeeper на отдельные VM.

---

## Ссылки

- Полная документация: [../CLUSTER_DOCUMENTATION.md](../CLUSTER_DOCUMENTATION.md)
- ClickHouse документация: https://clickhouse.com/docs
- ZooKeeper документация: https://zookeeper.apache.org/doc/

---

## Поддержка

При возникновении проблем:
1. Проверить раздел Troubleshooting выше
2. Проверить логи сервисов
3. Обратиться к CLUSTER_DOCUMENTATION.md
4. Открыть issue в репозитории проекта
