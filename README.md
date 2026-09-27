# tnt-notifier

Уведомления дежурному о находках диагностики кластера Tarantool. Находка
появилась — тревога, ушла — отбой, держится долго — напоминание не чаще
заданного срока. Куда носить, решают приёмники: журнал узла, файл,
служба по HTTP, письмо — или свой.

```lua
local notifier = require('tnt.notifier')
notifier.configure({ sinks = { notifier.log.new(), notifier.http.new({ url = 'https://alerts.example.org/hook' }) } })
require('tnt.cluster').configure({ on_issues = notifier.on_issues })
```

Находки приносит диагностика
[`tnt-cluster-health`](https://github.com/tnt-skein/tnt-cluster-health):
уведомитель встаёт в её хук `on_issues` без обёрток. Зависит от
[`tnt-clock`](https://github.com/tnt-skein/tnt-clock),
[`tnt-disk`](https://github.com/tnt-skein/tnt-disk),
[`tnt-http`](https://github.com/tnt-skein/tnt-http),
[`tnt-log`](https://github.com/tnt-skein/tnt-log),
[`tnt-mail`](https://github.com/tnt-skein/tnt-mail),
[`tnt-must`](https://github.com/tnt-skein/tnt-must)
и [`tnt-external`](https://github.com/tnt-skein/tnt-external).

## Зачем

Диагностика знает о кластере всё, но рассказывает только тому, кто
спросит, а ночью не спрашивает никто. Уведомитель переворачивает это:
находки идут к человеку. Пакет делает для этого пять вещей:

- **Рассказывает о перемене, а не о каждом обходе.** Одна незакрытая
  находка за ночь иначе превратилась бы в тысячи писем.
- **Шлёт отбой.** Человек, получивший ночью тревогу и не получивший
  отбоя, поедет в офис.
- **Напоминает о долгоживущей находке** не чаще срока, по монотонным
  часам: перевод стенных не глушит напоминания и не выпускает их разом.
- **Отказ приёмника не роняет обход и не мешает остальным** — он
  становится записью в журнале.
- **Проводит находки через встроенный реестр проверок готовности.**
  Отказ проверки Tarantool поднимает предупреждением конфигурации,
  и тревога работает там, где настроен Prometheus, без единого
  приёмника.

## Установка

```sh
tt rocks install tnt-notifier --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-notifier.git
cd tnt-notifier && tt rocks make --server=https://tnt-skein.github.io/rocks
```

## Как пользоваться

### Настройка

```lua
notifier.configure({
    sinks = { notifier.log.new(), notifier.file.new({ path = '/var/log/tarantool/alerts.jsonl' }) },
    min_severity = 'critical',
    repeat_after = 1800,
    capacity = 4096,
    resolve = true,
})
```

| Поле | Что | По умолчанию |
|---|---|---|
| `sinks` | приёмники, в порядке отправки | `{}` — никуда |
| `min_severity` | с какой серьёзности слать: `warning` или `critical` | `'warning'` |
| `repeat_after` | через сколько секунд напоминать о находке, которая никуда не делась | `3600` |
| `capacity` | сколько находок помнить | `1024` |
| `resolve` | слать ли отбой | `true` |

Негодная настройка — не таблица, незнакомый ключ, значение не того типа,
нулевой срок или потолок, приёмник без списка — бросок на строке
вызывающего, а не отказ в журнале на каждом обходе. Приёмники проверяют
свои настройки при сборке так же.

### Тревога, отбой, напоминание

```lua
local told = {}
local catcher = {
    name = 'ловец',
    send = function(event)
        table.insert(told, event.state)
    end,
}
local finding = { id = 'disk:instance:storage-001-b', severity = 'critical', message = 'каталог данных исчез' }

notifier.configure({ sinks = { catcher }, repeat_after = 1 })

notifier.on_issues({ finding }) -- raised
notifier.on_issues({ finding }) -- тишина: находка уже рассказана
require('fiber').sleep(1.5)
notifier.on_issues({ finding }) -- reminded: срок в секунду прошёл
notifier.on_issues({}) -- resolved
notifier.on_issues({ finding }) -- raised: вернулась

--> told = { 'raised', 'reminded', 'resolved', 'raised' }
```

Приёмник — таблица с `name` (строка) и `send(event)`; `send` возвращает
`nil`, если событие принято, или строку с причиной отказа.

### Приёмники

| Приёмник | Куда |
|---|---|
| `notifier.log.new()` | журнал узла: тревога и предупреждение — уровнем `warn` |
| `notifier.file.new({ path })` | файл: строка JSON на событие, дозаписью |
| `notifier.http.new({ url, timeout, headers })` | `POST` с событием в теле JSON; срок 2 с, без повторов, удача — любой `2xx` |
| `notifier.mail.new({ to, from })` | письмо почтой `tnt-mail`: тема `[ТРЕВОГА] storage-001-a: реплика отстала` |

### Встроенный реестр проверок готовности

```lua
notifier.configure({ sinks = { catcher } })
notifier.on_issues({ finding })
notifier.publish_health_checks()

local alerts = require('config'):info().alerts
--> alerts[1].message:
--> Readiness health check "cluster.findings.disk:instance:storage-001-b" failed: critical: каталог данных исчез

notifier.on_issues({}) -- находка ушла: проверка снята, предупреждения нет
notifier.withdraw_health_checks()
```

Цена — встроенная готовность узла уведомителя: пока в кластере есть
находки, `box.info.health.readiness.status` — `false`.

## Проверки

```sh
make deps          # luatest, luacheck, luacov, cluacov, рок http и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (84 проверки; 110
мутантов в шести модулях). Живые проверки поднимают узел по конфигурации —
находка становится предупреждением и переживает перечитывание — и шлют
событие настоящему серверу HTTP.

## Документ

Полное описание с обоснованием решений: [docs/notifier.md](docs/notifier.md).

## Лицензия

MIT.
