rockspec_format = '3.0'

package = 'tnt-notifier'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-notifier.git',
    branch = 'main',
}

description = {
    summary = 'Уведомления дежурному о находках диагностики кластера: тревога, отбой, напоминание',
    detailed = [[
        Диагностика знает о кластере всё, что нужно, и рассказывает
        об этом тому, кто спросит. Беда в том, что ночью не спрашивает
        никто: находка живёт в панели, а человек спит — и узнаёт о ней
        утром, вместе с последствиями. Уведомитель переворачивает это:
        не человек ходит за находками, а находки идут к человеку.

        notifier.on_issues встаёт в хук обхода диагностики и шлёт событие
        на перемену состояния: находка появилась (raised), ушла (resolved),
        а долгоживущая напоминает о себе (reminded) не чаще заданного срока,
        по монотонным часам. Порог серьёзности отсекает тихие находки,
        память о рассказанном ограничена потолком.

        Приёмники: журнал узла, файл строкой JSON на событие, POST
        на службу по HTTP с коротким сроком и без повторов, письмо почтой
        с темой, которой хватает вместо письма. Свой приёмник — таблица
        с name и send. Отказ приёмника пишется в журнал и не мешает
        остальным и обходу.

        notifier.publish_health_checks заводит каждую находку проверкой
        готовности во встроенном реестре Tarantool: её отказ становится
        предупреждением конфигурации в config:info().alerts, и тревога
        работает там, где настроен Prometheus, без единого приёмника.

        Негодная настройка уведомителя или приёмника — бросок на строке
        вызывающего, а не отказ в журнале на каждом обходе.

        Зависит от tnt-clock (часы), tnt-disk (дозапись файла), tnt-http
        (клиент HTTP), tnt-log (журнал), tnt-mail (письмо), tnt-must
        (проверка настроек) и tnt-external (подмена часов, реестра, диска
        и клиента в проверках). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-notifier',
    issues_url = 'https://github.com/tnt-skein/tnt-notifier/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'notifications', 'alerting', 'monitoring', 'health', 'mail', 'webhook' },
}

dependencies = {
    'lua >= 5.1',
    -- Стенные часы — дата события, монотонные — срок напоминания.
    'tnt-clock',
    -- Дозапись строки события в файл приёмника file.
    'tnt-disk',
    -- Клиент HTTP приёмника http: короткий срок, повторы выключены.
    'tnt-http',
    -- Журнал узла: приёмник log и записи об отказах приёмников.
    'tnt-log',
    -- Письмо приёмника mail.
    'tnt-mail',
    -- Проверка настроек уведомителя и приёмников: бросок с местом вызывающего.
    'tnt-must',
    -- Подмена часов, реестра проверок, диска и клиента в проверках.
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.notifier'] = 'tnt/notifier.lua',
        ['tnt.notifier.settings'] = 'tnt/notifier/settings.lua',
        ['tnt.notifier.sink.log'] = 'tnt/notifier/sink/log.lua',
        ['tnt.notifier.sink.file'] = 'tnt/notifier/sink/file.lua',
        ['tnt.notifier.sink.http'] = 'tnt/notifier/sink/http.lua',
        ['tnt.notifier.sink.mail'] = 'tnt/notifier/sink/mail.lua',
    },
}
