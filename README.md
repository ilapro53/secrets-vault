# 🔐 Secrets Vault

Command-bound OTP-gated secret manager для Linux.

## Архитектура

```
Ты (телефон)                Сервер (host)
┌─────────────────┐         ┌──────────────────────────┐
│ HTML-приложение  │         │ secrets-bash-executor    │
│ Вводишь команду  │◄─код──►│ secrets-verify           │
│ → получаешь 6    │         │ secret-exec              │
│   цифр           │         │ pass-store (GPG)         │
└─────────────────┘         └──────────────────────────┘
       ↑                          ↑
       └── ты говоришь код ───────┘
                (агент не видит секрет)
```

## Установка

```bash
git clone <url> && cd secrets-vault
chmod +x setup-secrets.sh && sudo ./setup-secrets.sh
```

## Компоненты

| Файл | Назначение |
|------|-----------|
| `setup-secrets.sh` | Полная установка с нуля (idempotent) |
| `secrets-otp` | Генерация кода (TOTP / command-bound) |
| `secrets-verify` | Проверка кода (с окном ±10 мин) |
| `secret-exec` | Выполнение готовой команды из pass (OTP-gated) |
| `secrets-bash-executor` | Выполнение произвольного bash-скрипта с подстановкой секретов из pass |
| `secrets-uri` | Показать QR для телефона (root-only) |
| `index.html` | Приложение для телефона (offline) |

## Рабочий процесс

### Режим 1: Готовая команда (через pass)

1. **Агент**: "Нужен `ssh/deploy`. Открой приложение, введи эту команду."
2. **Ты**: Открываешь vault → вводишь `ssh/deploy` → получаешь **6 цифр**
3. **Ты** → **Агенту**: `482719`
4. **Агент**: `secret-exec --code 482719 ssh/deploy -- ssh-add -`
5. **Система**: проверяет HMAC-SHA1(secret, `ssh/deploy|time`) → совпал → выполняет
6. **Секрет не появляется в логах агента**

### Режим 2: Произвольный скрипт (через secrets-bash-executor)

Агент может сам написать bash-скрипт с любыми командами, а секреты (из pass) подставятся автоматически.

1. **Агент** присылает:

```bash
secrets-bash-executor --secrets VPS_HOST,VPS_KEY - <<'SCRIPT'
ssh -i "$VPS_KEY" root@"$VPS_HOST" 'uptime && free -h'
SCRIPT
```

2. **Ты**: копируешь **всё** (от `secrets-bash-executor` до `SCRIPT`) → переключаешься на вкладку "Полный скрипт" в vault → вставляешь → получаешь `482719-123456`

3. **Ты** → **Агенту**: `482719-123456`

4. **Агент** запускает с `--code`:

```bash
secrets-bash-executor --secrets VPS_HOST,VPS_KEY --code 482719-123456 - <<'SCRIPT'
ssh -i "$VPS_KEY" root@"$VPS_HOST" 'uptime && free -h'
SCRIPT
```

5. **Система**:
   - Реконструирует исходный текст (без `--code`)
   - Сверяет HMAC-SHA1(secret, full_text|time)
   - Подгружает `$VPS_HOST` и `$VPS_KEY` из pass
   - Экспортирует их как переменные окружения
   - Выполняет скрипт

**Ключевое:** код привязан ко всему тексту скрипта. Изменишь хоть букву — код станет другим. Агент не видит значения секретов — переменные подставляются на сервере.

## Алгоритм

- **TOTP (без команды)**: `HMAC-SHA1(key, time/30)` — совместим с Google Authenticator
- **Command-bound**: `HMAC-SHA1(key, "cmd|time/300")` — уникален для каждой команды
- **Script-bound (secrets-bash-executor)**: `HMAC-SHA1(key, full_text|time/300)` — привязан ко всему тексту скрипта
- **Окно**: 5 минут (±1 окно = 15 минут валидности)
