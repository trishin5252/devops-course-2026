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

Все три снимка созданы на выключенной машине:

1. `01-clean-install` — Ubuntu установлена и обновлена, есть student,
   OpenSSH и оба интерфейса; рабочий devops ещё не создан.
2. `02-keys-configured` — devops создан, входит по ключу, права 700/600,
   SSH внутри гостя ещё на порту 22.
3. `03-ssh-hardened` — SSH на 2222, root и пароли запрещены, новый доступ
   проверен; UFW и окончательное доменное имя настраивались после снимка.

Возврат на первый снимок также возвращает исходный проброс порта 22.
Повторить создание пользователя и ключевой доступ, настройки SSH,
смену гостевого порта проброса, UFW и hostname. Образ ISO уже не требуется.
Файлы Windows, ключи и hosts снимком виртуальной машины не откатываются.

## 8. Имя узла и особенность сети Windows

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

## 9. Скрипт аудита

Файл `scripts/audit.sh` выполняет шесть проверок. Запускать на сервере:

```bash
bash scripts/audit.sh
echo $?
```

На правильной конфигурации получено Passed: 6, failed: 0 и код 0.
При временном MaxAuthTries 10 получено Passed: 5, failed: 1 и код 1.
После опыта восстановлено MaxAuthTries 3, повторная проверка завершилась
кодом 0. Запуск sshd с неверным лимитом для этой проверки не требовался:
скрипт анализирует эффективную конфигурацию через `sshd -T`.
