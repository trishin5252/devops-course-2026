# Конфигурация виртуальной машины devops-vm

## 1. Параметры машины

VirtualBox 7.2.12, Ubuntu Server 24.04.5 LTS без графического рабочего стола.
Память 2048 МБ, 2 виртуальных CPU, динамический диск VDI 25 ГБ.
Имя машины `devops-vm`, полное имя `devops-vm.devops.local`.

## 2. Сетевые интерфейсы

| Интерфейс | Адаптер | Адрес IPv4 | Назначение |
| --- | --- | --- | --- |
| enp0s3 | NAT | 10.0.2.15/24 | Интернет и вход через проброс порта |
| enp0s8 | Host-only | 192.168.56.101/24 | Связь с Windows и будущим веб-сервером |

Оба адреса назначает DHCP VirtualBox. Адрес Windows в сети Host-only —
`192.168.56.1/24`. Проверка: `ip -brief address`.

## 3. Правило проброса портов

Начальная установка: TCP `127.0.0.1:2222` Windows → порт `22` гостя.
После настройки SSH: TCP `127.0.0.1:2222` Windows → порт `2222` гостя.
Адрес гостя в правиле не заполнен. Имя правила — `ssh`.

Правило VirtualBox при работающей VM меняется командами Windows:

```powershell
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' controlvm devops-vm natpf1 delete ssh
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' controlvm devops-vm natpf1 'ssh,tcp,127.0.0.1,2222,,2222'
```

## 4. Учётные записи

- `student`, UID 1000: исходный пользователь установки, группа sudo.
- `devops`, UID 1001: рабочий пользователь, группы devops, sudo и users.
- Удалённый доступ разрешён только `devops` по отдельному ключу Ed25519.
- Пароли для консоли и sudo сохранены только локально, в Git они не включены.

Создание пользователя после отката на исходный снимок:

```bash
sudo adduser devops
sudo usermod -aG sudo devops
groups devops
```

Публичный ключ Windows: `%USERPROFILE%\.ssh\devops_vm.pub`.
Закрытый ключ остаётся в Windows и на сервер не копируется.
Разместить публичный ключ в `/home/devops/.ssh/authorized_keys`;
владелец каталога и файла — devops, права каталога `700`, файла `600`.

Пример настройки с Windows PowerShell на исходной конфигурации:

```powershell
Get-Content "$env:USERPROFILE\.ssh\devops_vm.pub" | ssh -p 2222 devops@127.0.0.1 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

Ключ хоста сверяется с консолью VM командой
`sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
Проверенный отпечаток Ed25519:
`SHA256:5QdDrdXcbyliekaVCupMfjPYKR8w13bMd1Ysw4lSaBs`.

На хосте в `%USERPROFILE%\.ssh\config` добавлены алиасы `devops`
для `127.0.0.1:2222` и `devops.local` для прямого подключения по имени.
Оба используют пользователя devops, `devops_vm` и `IdentitiesOnly yes`.
Для путей к ключу и отдельному known_hosts использован короткий путь профиля
`C:/Users/2E9D~1/.ssh/`, поскольку часть SSH-инструментов некорректно
обрабатывала кириллицу в пути.

## 5. Служба SSH

Оригинал `/etc/ssh/sshd_config` сохранён как `/etc/ssh/sshd_config.backup`.
Настройки находятся в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```text
Port 2222
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Если в более раннем файле `/etc/ssh/sshd_config.d/` стоит
`PasswordAuthentication yes`, эту строку нужно закомментировать.
В OpenSSH применяется первое найденное значение параметра.

Порядок применения, при котором старое SSH-соединение остаётся открытым:

```bash
sudo sshd -t
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers) '
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh.service
sudo ss -tlnp | grep sshd
```

После смены проброса открыть второе соединение `ssh devops` и проверить его.
Только после успешной проверки закрыть первое соединение.
Проверены успешный вход devops по ключу, отказ root и отказ при
`PubkeyAuthentication=no`. В обоих отрицательных опытах клиент вывел
`Permission denied (publickey)`. На сервере журнал отдельно указал,
что root отсутствует в AllowUsers. Одинаковое клиентское сообщение
не означает одинаковую причину отказа.

## 6. Правила межсетевого экрана

UFW включён и запускается вместе с системой. Политики: входящие deny,
исходящие allow, маршрутизируемый трафик disabled. Разрешены:

| Порт TCP | Действие | Назначение |
| --- | --- | --- |
| 2222 | LIMIT IN | SSH с ограничением частоты подключений |
| 80 | ALLOW IN | HTTP для следующей практики |
| 443 | ALLOW IN | HTTPS |

Эти правила присутствуют для IPv4 и IPv6. Журналирование — medium.
Восстановление после исходного снимка:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
sudo ufw status verbose
```

Правило SSH обязательно создаётся до `ufw enable`.
Проверку `ufw allow ssh` использовать нельзя: символьное имя ssh относится
к порту 22 из `/etc/services`, а текущий SSH слушает 2222.

Блокировка порта 8080 проверена запросом Windows через временный
NAT-проброс `127.0.0.1:28080` → guest:8080. Временное правило после
проверки удалено. Запись UFW BLOCK содержит SRC=10.0.2.2 (хост в NAT),
DST=10.0.2.15 (гость), PROTO=TCP, DPT=8080 (порт назначения).

## 7. Снимки состояния

Снимки созданы на выключенной машине:

1. `01-clean-install` — Ubuntu установлена и обновлена, есть student,
   OpenSSH и оба интерфейса; рабочий devops ещё не создан.
2. `02-keys-configured` — devops создан, входит по ключу, права 700/600,
   SSH внутри гостя ещё на порту 22.
3. `03-ssh-hardened` — SSH на 2222, root и пароли запрещены, новый доступ
   проверен; UFW и окончательное доменное имя настраивались после снимка.
4. `04-nginx-https` — Nginx, HTTP301, HTTPS с SAN, ключ root600,
   временная страница и расширенный аудит. Снимок создан до доставки site/.
5. `05-docker-compose` — Docker Engine и Compose, приложение и PostgreSQL,
   файл .env только на сервере, именованный том и приватный порт5000.
   В фактическом снимке также сохранены /app/ в Nginx и расширенный аудит.
   Создан на корректно выключенной машине; после запуска службы проверены.

Перед проверкой восстановления ПР5 дополнительно сохранён снимок
`pr6-before-recovery`. Восстановление из 01-clean-install с повторной
настройкой devops, SSH, UFW и FQDN заняло 79.5 секунд, аудит6/6exit0.

Возврат на первый снимок также возвращает исходный проброс порта 22.
Повторить создание пользователя и ключевой доступ, настройки SSH,
смену гостевого порта проброса, UFW и hostname. Образ ISO уже не требуется.
Файлы Windows, ключи и hosts снимком виртуальной машины не откатываются.

## 8. Веб-сервер

Установлены пакеты `nginx` (Ubuntu 1.24.0) и `rsync`.
Главный процесс Nginx — root, рабочие — www-data.
Ресурс описан в `/etc/nginx/sites-available/devops-site`, активируется
ссылкой `/etc/nginx/sites-enabled/devops-site`. Ссылка `default` отключена,
исходный `/etc/nginx/sites-available/default` сохранён.

Каталог `/var/www/devops-site` принадлежит devops:devops, каталоги имеют
права 755, файлы 644. www-data читает файлы и не может менять содержимое.
Сначала опубликована временная страница `devops.local: placeholder`.
Итоговые HTML-файлы из `site/` ветки `feature/web-deploy` доставлены
с Windows из Ubuntu-DevOps (Ubuntu22.04, WSL1) через rsync.
На разделе /mnt/c файлы имели режим 777, после --chmod=D755,F644
на сервере получены 755 для каталога и 644 для файлов. Собственная 404-страница
отдаётся с кодом 404. Полная конфигурация сохранена в
`configs/nginx/devops-site.conf`; её можно установить sudo install -m 644
в /etc/nginx/sites-available/devops-site, создать ссылку sites-enabled
и после `nginx -t` выполнить reload.

Самоподписанный RSA2048 сертификат выпущен на 365 дней командой:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj '/CN=devops.local' \
  -addext 'subjectAltName=DNS:devops.local'
sudo chown root:root /etc/ssl/private/devops.key /etc/ssl/certs/devops.crt
sudo chmod 600 /etc/ssl/private/devops.key
sudo chmod 644 /etc/ssl/certs/devops.crt
```

Закрытый ключ остаётся только на сервере; копировать его в Git запрещено.
Публичный сертификат получен по проверенному SSH-каналу в `~/devops.crt`
на Windows. Срок: 22.10.2026 11:24:37 UTC — 22.10.2027 11:24:37 UTC.
Subject и issuer совпадают; SAN содержит DNS:devops.local.

HTTP80 возвращает 301 с `Location: https://devops.local/`.
HTTPS443 использует TLS1.2 и TLS1.3. HSTS для учебного сертификата не задан.
В блоке HTTPS сохранены root, index, try_files, error_page и отдельные
журналы `/var/log/nginx/devops-site.access.log` и `devops-site.error.log`.
Блок HTTP пишет в тот же access.log, чтобы учитывать 301 вместе с HTTPS.
После изменения конфигурации выполняется только:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Из-за VPN предварительная клиентская проверка Windows выполнена через
временные NAT-пробросы 127.0.0.1:18080→80 и 127.0.0.1:18443→443
с `curl --connect-to`, сохраняющим настоящее имя devops.local в запросе
и проверке TLS. Без доверенного сертификата curl завершился с кодом60
SEC_E_UNTRUSTED_ROOT; с `--cacert ~/devops.crt` — 200 OK без `-k`.
После установки WSL1 проверка повторена настоящим Linux-клиентом curl:
согласованы TLS 1.3 / TLS_AES_256_GCM_SHA384, HTTP/1.1 200,
Server nginx/1.24.0 (Ubuntu), Content-Type text/html, Content-Length 424.
Без --cacert получен curl 60 / self-signed certificate.
Это не заменяет будущую прямую проверку Host-only и скриншоты браузера.
Пробросы удалялись перед 04-nginx-https, затем временно добавлялись
для тестов WSL под VPN и удаляются после завершения этих тестов.

## 9. Контейнеризация

Docker Engine Community 29.9.2 установлен из официального APT-репозитория
https://download.docker.com/linux/ubuntu для Ubuntu noble, ключ расположен
в /etc/apt/keyrings/docker.asc, источник — /etc/apt/sources.list.d/docker.sources.
Установлены docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin
и docker-compose-plugin (Compose v5.6.1). Пакет docker.io не используется.

Установка воспроизводится по https://docs.docker.com/engine/install/ubuntu/:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod 644 /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' | sudo tee /etc/apt/sources.list.d/docker.sources
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker devops
```

После добавления в группу необходимо новое SSH-соединение.
В группе docker состоит только devops, у которого уже есть sudo.
Доступ к Docker socket фактически даёт возможности root, а не обычные
ограниченные права контейнерного приложения. Проверка без sudo:
`docker run --rm hello-world`, `docker version`, `docker compose version`.

Исходники лежат в app/ репозитория. Серверный проект — /home/devops/app,
Compose project name по имени каталога — app. Доставка из WSL:

```bash
rsync -avz --delete --exclude=.env --chmod=D755,F644 --dry-run app/ devops:app/
rsync -avz --delete --exclude=.env --chmod=D755,F644 app/ devops:app/
```

Режимы нормализованы для файлов на /mnt/c. Исключение .env обязательно:
секрет создаётся только на сервере, а --delete не должен его удалять.
В Git и контекст Docker .env не входит. При восстановлении создаётся новый
случайный пароль, который не нужно печатать или копировать в Windows:

```bash
cd ~/app
umask 077
password=$(openssl rand -hex 16)
printf 'POSTGRES_DB=app\nPOSTGRES_USER=app\nPOSTGRES_PASSWORD=%s\nDB_HOST=db\n' "$password" > .env
unset password
chmod 600 .env
docker compose up -d --build --wait --wait-timeout 120
```

Этот блок создания .env выполняется только при отсутствии существующего файла:
замена пароля при уже существующем томе сама по себе не меняет пароль в БД.
Итоговый /home/devops/app/.env принадлежит devops, права 600.
База postgres:16-alpine хранит данные в томе app_db_data
(/var/lib/postgresql/data), доступна приложению по DNS-имени db
в сети app_backend. Порт 5432 не опубликован. Gunicorn слушает 5000
в контейнере от пользователя app (UID 999), на хост опубликован только
127.0.0.1:5000:5000. depends_on/service_healthy ждёт pg_isready.

Внутри HTTPS-блока /etc/nginx/sites-available/devops-site добавлено:

```nginx
location /app/ {
    proxy_pass http://127.0.0.1:5000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Статический location / сохранён. Конфигурация проверяется nginx -t
и применяется reload. /app/health передаётся как /health за счёт слеша
в proxy_pass. Проверки через HTTPS выполняются с --cacert, не с -k.

Эксперименты: отдельный app-test без БД дал health200/root500 и
ошибку localhost:5432; изменение только app.py повторно использовало
слои установки зависимостей. Счётчик 4 до down стал 5 после запуска;
после намеренного down -v только нового учебного тома начал с 1.
Новый итоговый том сохранён. На рабочей БД down -v недопустим.
При остановке app получен502 и connect() failed111 в Nginx; app восстановлен.
Временная публикация 5000 на всех адресах дала аудит13/1/exit1,
возврат127.0.0.1 восстановил14/0/exit0.
Временный exposed5001 продемонстрировал DNAT Docker и доступ с Windows
через временный NAT18501 при отсутствии правила UFW; контейнер и проброс
удалены. При включённом VPN прямая проверка Host-only не прошла.
Затем пользователь отключил VPN и выполнил с Windows прямой запрос
http://devops.local:5001/health — получен ok. Контейнер exposed
остановлен командой docker stop exposed и удалён благодаря --rm;
постоянного опубликованного порта5001 нет. Скриншот PowerShell сохранён.
В браузере отдельно подтверждены HTTPS/app/ со счётчиком8→9,
/app/health с ok и сохранённый статический ресурс по /.

## 10. Имя узла и особенность сети Windows

Внутри Ubuntu выполнены:

```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f
```

Результат — `devops-vm.devops.local`.
В hosts Windows внесена запись `192.168.56.101 devops.local`.
Подключение по имени подтверждено 22 октября 2026 года после временного
отключения AmneziaVPN. `ping -4 devops.local`: 4 ответа, 0 потерь.
`ssh -o BatchMode=yes -o ConnectTimeout=5 devops.local "whoami; hostname -f"`
возвращает `devops` и `devops-vm.devops.local` без запроса пароля.

Выявлен конфликт маршрутов: у AmneziaVPN и Host-only есть маршруты
`192.168.56.0/24`, маршрут VPN имеет более высокий приоритет.
Добавлен постоянный маршрут `192.168.56.101/32` через интерфейс Windows
с адресом 192.168.56.1; метрика маршрута и интерфейса VirtualBox равна 1.
Find-NetRoute выбирает Ethernet 2 (Host-only). При активном VPN прямое
соединение блокировалось ещё до SSH-аутентификации с ошибкой
`connect to host devops.local port 2222: Permission denied`.
Пользователь временно отключил VPN и самостоятельно подтвердил ping и SSH
скриншотом. Защита Windows и Ubuntu для этого не отключалась.
Доступ через NAT командой `ssh devops` тоже работает.
Блокировка 8080 подтверждена через NAT, как описано в разделе 6;
отдельный успешный опыт блокировки через Host-only не зафиксирован.

## 11. Скрипт аудита

В ПР5 файл `scripts/audit.sh` выполнял шесть проверок SSH и UFW.
В ПР6 добавлены четыре проверки веб-сервера, всего десять. Запускать на сервере:

```bash
bash scripts/audit.sh
echo $?
```

На правильной конфигурации получено Passed: 6, failed: 0 и код 0.
При временном MaxAuthTries 10 получено Passed: 5, failed: 1 и код 1.
После опыта восстановлено MaxAuthTries 3, повторная проверка завершилась
кодом 0. Запуск sshd с неверным лимитом для этой проверки не требовался:
скрипт анализирует эффективную конфигурацию через `sshd -T`.

Раздел веб-сервера проверяет активность nginx, успешность nginx -t,
срок сертификата не менее 30 дней, а также совместное условие: нет путей
с записью для всех и режим закрытого ключа равен 600.
Проверены 10 PASS/0 FAIL/exit0 и два отрицательных опыта:
`CERT_MIN_DAYS=400 bash /home/devops/audit.sh` даёт 9 PASS/1 FAIL/exit1;
временные права 666 у index.html дают 9 PASS/1 FAIL/exit1.
Права восстановлены в 644, окончательный аудит — 10 PASS/0 FAIL/exit0.

В ПР7 добавлен раздел [5] с четырьмя проверками Docker, здоровья БД,
приватной публикации портов5000/5432 и режима .env600.
Нормальное состояние —14PASS/0FAIL/exit0. Публикация5000на всех адресах
вызывает13PASS/1FAIL/exit1,после восстановления127.0.0.1сноваexit0.

## 12. Подготовленный сценарий деплоя

В ветке feature/web-deploy подготовлен `scripts/deploy.sh`.
Он вычисляет корень репозитория относительно своего пути, проверяет наличие
site/index.html и чистоту Git, выполняет ровно один rsync по SSH с
BatchMode=yes и ConnectTimeout=5, --delete и --chmod=D755,F644.
При --dry-run не изменяет ресурс и не запускает HTTP-проверку.
Обычный запуск проверяет https://devops.local с ~/devops.crt без -k
и выводит короткий хеш только при успехе. Для shell-файлов .gitattributes
закрепляет окончания строк LF.
Все пять сценариев выполнены из настоящего WSL1:

1. --dry-run: exit0, контрольные суммы сервера до/после совпали.
2. Закоммиченная правка: exit0, новый текст получен по HTTPS.
3. Незакоммиченная и отдельно staged правки: exit1, сервер не меняется.
4. Nginx остановлен: rsync прошёл, HTTPS-проверка далаexit1; Nginx запущен
   обратно в finally даже при ошибке теста.
5. index.html переименован и закоммичен: exit1 до rsync, удалённая
   главная страница сохранена; имя восстановлено отдельным коммитом.

После всех опытов выполнен успешный штатный деплой.
Для проверки через временный NAT при включённом VPN используется:

```bash
DEPLOY_CONNECT_TO=devops.local:443:127.0.0.1:18443 bash scripts/deploy.sh
```

Это только изменение транспорта curl, а не URL/Host/SAN и не отключение TLS.
При прямом Host-only доступе переменная не нужна, а NAT 18443 не требуется.
SSH-мультиплексирование в конфигурации WSL уменьшает частоту соединений
и не ослабляет серверное правило UFW LIMIT.

## 13. Подготовка WSL1 и результаты диагностики

В Windows включена только Microsoft-Windows-Subsystem-Linux, выполнена
перезагрузка. `wsl --set-default-version 1`. Официальный Ubuntu22.04 rootfs
импортирован командой `wsl --import Ubuntu-DevOps <каталог> <архив> --version 1`.
Проверенная SHA256: de9f6149da07b90350a3ccd94b4858b82fef71f0ec2982acb93de583c4c87585.
Hyper-V и VirtualMachinePlatform не включались. В `wsl -l -v` указана VERSION 1,
`uname -r` возвращает 4.4.0-19041-Microsoft. Сервер остался Ubuntu 24.04.

Внутри WSL создан пользователь devops и задан в /etc/wsl.conf как default.
SSH-ключ скопирован только в его домашний каталог с правами 600 и .ssh 700;
Linux-конфигурация использует ~/.ssh, а не Windows-пути C:/Users/.
Публичный сертификат находится в /home/devops/devops.crt.
Установлены rsync 3.2.7, curl 7.81.0, git и openssh-client.
Для общего Windows-репозитория core.fileMode=false и core.autocrlf=true
исключают ложные изменения; .gitattributes сохраняет LF у .sh и HTML.
Ни содержимое прежних файлов, ни настройки других репозиториев не менялись.

Проверки прав: файл 600 → HTTP 403 / open() failed (13); каталог 755 → 200,
750 → 403, 744 → 403, 711 → 200. При 711 ls от www-data запрещён, cat успешен.
Rsync без --chmod перенёс 777, после чего www-data смог заменить index.html
на defaced. Обычный deploy.sh восстановил и содержимое, и 755/644;
`find /var/www/devops-site -perm -o+w` пустой, www-data touch запрещён.

Разнородные запросы: три GET / → 200, /admin, /wp-login.php, /.env → 404,
HTTP / → 301. На момент снимка журнал содержал 20 ответов 200, 4 ответа 404,
3 ответа 403 и 1 ответ 301; счётчик включает прежние эксперименты.
Адрес 10.0.2.2 в этих записях соответствует NAT, не Host-only.
Клиент curl/7.81.0, время с зоной +0300; код и размер тела — поля 9 и 10.
Прямая браузерная проверка ПР6 по devops.local выполнена пользователем
с отключённым VPN: главная страница,404,самоподписанный сертификат и SAN.
Они включены в отчёт ПР6. Для приложения ПР7 нужны отдельные новые кадры.
