# 🔐 Secrets Vault

Command-bound OTP-gated secret manager для Linux.

## Архитектура

```
Ты (телефон)                Сервер (host)
┌─────────────────┐         ┌─────────────────────┐
│ HTML-приложение  │         │ secrets-otp (Python)│
│ Вводишь команду  │◄─код──►│ secrets-verify      │
│ → получаешь 6    │         │ secret-exec         │
│   цифр           │         │ pass-store (GPG)    │
└─────────────────┘         └─────────────────────┘
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
| `secret-exec` | Выполнение команды с секретом (OTP-gated) |
| `secrets-uri` | Показать QR для телефона (root-only) |
| `secrets-vault-app.html` | Приложение для телефона (offline) |

## Рабочий процесс

1. **Агент**: "Нужен `ssh/deploy`. Открой приложение, введи эту команду."
2. **Ты**: Открываешь vault.html → вводишь `ssh/deploy` → получаешь **6 цифр**
3. **Ты** → **Агенту**: "482719"
4. **Агент**: `secret-exec --code 482719 ssh/deploy -- ssh-add -`
5. **Система**: проверяет HMAC-SHA1(secret, `ssh/deploy|time`) → совпал → выполняет
6. **Секрет не появляется в логах агента**

## Алгоритм

- **TOTP (без команды)**: `HMAC-SHA1(key, time/30)` — совместим с Google Authenticator
- **Command-bound**: `HMAC-SHA1(key, "cmd|time/600")` — уникален для каждой команды
- **Окно**: 10 минут (±1 окно = 30 минут валидности)
