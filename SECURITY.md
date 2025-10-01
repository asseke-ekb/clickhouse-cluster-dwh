# Рекомендации по безопасности

## ⚠️ ПЕРЕД ЗАЛИВКОЙ В GIT

### 1. Проверьте, что следующие файлы НЕ попали в Git:

```bash
# Проверить, что файлы игнорируются
git status --ignored

# Должны быть проигнорированы:
# - logs/
# - .env
# - config/users.xml (только если содержит реальные пароли)
```

### 2. Файлы с паролями

**НЕ КОММИТИТЬ**:
- `config/users.xml` - если содержит реальные пароли
- `.env` файлы с реальными данными
- Любые файлы с суффиксом `.secret`, `.key`, `.pem`

**МОЖНО КОММИТИТЬ**:
- `config/users.xml.example` - шаблон без паролей
- `.env.example` - шаблон без реальных данных
- Все остальные конфиги (config.xml, haproxy.cfg, prometheus.yml)

---

## 🔒 Чеклист безопасности перед развертыванием

### Обязательные действия:

- [ ] **Изменить все пароли**
  - [ ] ClickHouse admin (`config/users.xml`)
  - [ ] Grafana admin (`docker-compose.yml` → `GF_SECURITY_ADMIN_PASSWORD`)

- [ ] **Создать .env файл из .env.example**
  ```bash
  cp production-deployment/.env.example production-deployment/.env
  # Отредактировать .env и заменить все значения
  ```

- [ ] **Обновить IP адреса**
  - [ ] В `production-deployment/.env`
  - [ ] В `/etc/hosts` на всех VM
  - [ ] В `docker-compose.yml` файлах ZooKeeper (ZOO_SERVERS)

- [ ] **Настроить firewall на всех VM**
  - [ ] ClickHouse nodes: порты 8123, 9000, 9009, 9363
  - [ ] ZooKeeper nodes: порты 2181, 2888, 3888
  - [ ] Infrastructure: порты 8080-8082, 8404, 9090-9091, 9099, 3000

- [ ] **Ограничить доступ**
  - [ ] SSH только по ключам (отключить пароли)
  - [ ] Доступ к VM только через VPN или bastion host
  - [ ] Ограничить доступ к ClickHouse по IP в users.xml

- [ ] **SSL/TLS (рекомендуется)**
  - [ ] Настроить SSL сертификаты для ClickHouse
  - [ ] Настроить HTTPS для HAProxy
  - [ ] Настроить HTTPS для Grafana

---

## 🔐 Генерация паролей

### Сгенерировать сильные пароли:

```bash
# Генерация случайного пароля (32 символа)
openssl rand -base64 32

# Или
pwgen 32 1
```

### Для ClickHouse (SHA256):

```bash
# Создать пароль с SHA256
PASSWORD=$(echo -n "your_password" | sha256sum | tr -d '-')
echo $PASSWORD
```

В `config/users.xml`:
```xml
<admin>
    <password_sha256_hex>HASH_HERE</password_sha256_hex>
</admin>
```

---

## 🛡️ Настройки безопасности ClickHouse

### 1. Ограничение по IP

В `config/users.xml`:
```xml
<admin>
    <networks>
        <!-- Разрешить только с конкретных IP -->
        <ip>10.0.1.5</ip>
        <ip>10.0.1.0/24</ip>
    </networks>
</admin>
```

### 2. Readonly пользователи

Для аналитических пользователей:
```sql
CREATE USER analyst
IDENTIFIED WITH sha256_password BY 'password'
SETTINGS readonly = 1;
```

### 3. Row-level Security

Ограничение доступа к строкам:
```sql
CREATE ROW POLICY tenant_isolation ON events
FOR SELECT USING tenant_id = currentUser() TO analyst;
```

---

## 🔍 Аудит и мониторинг

### 1. Включить аудит логов

На всех VM установить `auditd`:
```bash
sudo apt-get install auditd
sudo systemctl enable auditd
sudo systemctl start auditd
```

### 2. Мониторинг неудачных входов

В ClickHouse проверять:
```sql
SELECT
    event_time,
    user,
    client_hostname,
    client_name,
    exception
FROM system.query_log
WHERE exception LIKE '%Authentication failed%'
ORDER BY event_time DESC
LIMIT 100;
```

### 3. Настроить алерты в Prometheus

Создать файл `/opt/prometheus/alerts/security.yml`:
```yaml
groups:
  - name: security
    rules:
      - alert: FailedLogins
        expr: rate(clickhouse_failed_queries[5m]) > 10
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High rate of failed queries"
```

---

## 📦 Backup паролей и секретов

### Безопасное хранение

1. **Использовать менеджер паролей** (1Password, LastPass, Bitwarden)
2. **Encrypted файл** на отдельном сервере:
   ```bash
   # Зашифровать секреты
   gpg --symmetric --cipher-algo AES256 secrets.txt

   # Расшифровать
   gpg --decrypt secrets.txt.gpg
   ```
3. **Vault** (HashiCorp Vault) для enterprise

### Что хранить

- [ ] Все пароли ClickHouse (admin, users)
- [ ] Пароли Grafana
- [ ] SSH ключи
- [ ] SSL сертификаты и приватные ключи
- [ ] Backup encryption keys

---

## 🚨 Что делать при компрометации

### 1. Немедленно:

```bash
# Остановить все сервисы
docker compose down

# Отключить VM от сети
sudo ufw deny all

# Сменить все пароли
```

### 2. Ротация паролей:

```sql
-- В ClickHouse
ALTER USER admin IDENTIFIED WITH sha256_password BY 'new_password';

-- Проверить активные сессии
SELECT * FROM system.processes;

-- Убить подозрительные сессии
KILL QUERY WHERE query_id = 'xxx';
```

### 3. Анализ:

```bash
# Проверить логи
tail -f /var/log/clickhouse/clickhouse-server.log
tail -f /var/log/auth.log

# Проверить активные подключения
netstat -antp | grep ESTABLISHED
```

---

## 📋 Compliance

### GDPR / Персональные данные

Если храните персональные данные:

1. **TTL для автоматического удаления**:
   ```sql
   CREATE TABLE users (
       user_id UInt64,
       email String,
       created_at DateTime
   ) ENGINE = MergeTree()
   ORDER BY user_id
   TTL created_at + INTERVAL 90 DAY DELETE;
   ```

2. **Row-level политики для доступа**
3. **Аудит всех SELECT запросов с персональными данными**
4. **Шифрование на уровне диска** (LUKS)

---

## 📞 Контакты при инциденте

| Роль | Контакт |
|------|---------|
| Security Lead | `<заполнить>` |
| DevOps Lead | `<заполнить>` |
| DBA | `<заполнить>` |

---

## 📚 Дополнительные ресурсы

- [ClickHouse Security](https://clickhouse.com/docs/en/operations/security)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker)
