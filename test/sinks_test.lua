--- Тесты приёмников: журнал, файл и чужая служба по HTTP.

local t = require('luatest')
local json = require('json')

local g = t.group('tnt.notifier.sinks')

local helper = dofile('test/helper.lua')
local testing = helper.testing

--- Приёмники с тем, что они берут при загрузке: почтой и слоем диска.
local Module = helper.MODULES

--- Приёмники: каждый берётся отдельной ссылкой, потому что вывод типов
--- по таблице с тремя модулями считает её полями неизвестно что.
---@type any
local log_sink

---@type any
local file_sink

---@type any
local http_sink

---@type any
local mail_sink

---@type any
local fake

--- Что и куда отправлял клиент HTTP.
---@type any
local requests

--- Чем отвечает служба.
---@type any
local answer

--- Событие уведомления.
---@param overrides table|nil
---@return table
local function event(overrides)
    local entry = {
        state = 'raised',
        at = 1789041300,
        id = 'replication:instance:storage-001-a',
        severity = 'critical',
        rule = 'replication',
        instance = 'storage-001-a',
        message = 'реплика отстала',
    }

    for key, value in pairs(overrides or {}) do
        entry[key] = value
    end

    return entry
end

g.before_each(function()
    requests = {}
    answer = { status = 200 }

    log_sink = testing.load_sources(Module, 'tnt.notifier.sink.log')
    fake = helper.use_disk()
    file_sink = testing.module('tnt.notifier.sink.file')
    http_sink = testing.module('tnt.notifier.sink.http')
    mail_sink = testing.module('tnt.notifier.sink.mail')

    http_sink._set_source({
        client = function(timeout)
            return {
                post = function(_, url, opts)
                    table.insert(requests, { method = 'POST', url = url, opts = opts, timeout = timeout })

                    if type(answer) == 'string' then
                        return nil, answer
                    end

                    return setmetatable(answer, {
                        __index = {
                            ok = function(self)
                                return type(self.status) == 'number' and self.status >= 200 and self.status < 300
                            end,
                        },
                    })
                end,
            }
        end,
    })
end)

g.after_each(function()
    http_sink._set_source(nil)
    helper.release_disk()
    testing.unload_sources(Module)
end)

-- ── Журнал ───────────────────────────────────────────────────────────

g.test_log_sink_writes_the_finding = function()
    -- Приёмник по умолчанию и единственный, который работает всегда:
    -- сети может не быть, каталога может не быть, а журнал есть.
    local journal = testing.capture_log()

    journal.forget()
    log_sink.new().send(event())

    t.assert_equals(journal.logged('находка raised'), true)
    t.assert_equals(journal.logged('реплика отстала'), true)
end

g.test_log_sink_shouts_about_the_loud_ones = function()
    -- Тревога пишется предупреждением, а не ошибкой: ошибка в журнале
    -- узла означает, что сломался сам узел, а здесь сломалось что-то
    -- в кластере, и узел об этом рассказывает. Неизвестный уровень
    -- не будит никого — он идёт обычной записью.
    --
    -- Журнал подменяется целиком: приёмник его записей не читает,
    -- и проверить уровень можно только там, где его выбирают.
    local calls = {}
    local real = package.loaded['tnt.log']

    package.loaded['tnt.log'] = {
        new = function()
            return {
                warn = function(message)
                    table.insert(calls, { level = 'warn', message = message })
                end,

                info = function(message)
                    table.insert(calls, { level = 'info', message = message })
                end,
            }
        end,
    }

    local sink = testing.load_sources(helper.LOG_SINK, 'tnt.notifier.sink.log')

    sink.new().send(event({ severity = 'critical' }))
    sink.new().send(event({ severity = 'warning' }))
    sink.new().send(event({ severity = 'наблюдение' }))

    package.loaded['tnt.log'] = real

    t.assert_equals(calls[1].level, 'warn')
    t.assert_equals(calls[2].level, 'warn')
    t.assert_equals(calls[3].level, 'info')
    t.assert_str_contains(calls[1].message, 'находка raised')
end

-- ── Файл ─────────────────────────────────────────────────────────────

g.test_file_sink_appends_a_line_per_event = function()
    -- События идут вперёд, и каждое ложится в конец: переписывание
    -- потеряло бы всё, что было до него.
    local sink = file_sink.new({ path = '/var/notify/app.jsonl' })

    t.assert_equals(sink.send(event()), nil)
    t.assert_equals(sink.send(event({ state = 'resolved' })), nil)

    local lines = {}

    for line in fake.contents['/var/notify/app.jsonl']:gmatch('[^\n]+') do
        table.insert(lines, json.decode(line))
    end

    t.assert_equals(#lines, 2)
    t.assert_equals(lines[1].state, 'raised')
    t.assert_equals(lines[2].state, 'resolved')
end

g.test_file_sink_reports_a_refusal = function()
    fake.append_error = 'нет прав на запись'

    local sink = file_sink.new({ path = '/var/notify/app.jsonl' })

    t.assert_str_contains(sink.send(event()), 'нет прав')
end

g.test_file_sink_without_a_path_is_refused_on_the_callers_line = function()
    -- Путь не выдумывается: файл уведомлений рядом с данными узла —
    -- это файл, который никто не читает. А приёмник без пути отказывал бы
    -- на каждом событии, и видно это было бы только в журнале.
    local cases = {
        { nil, 'настройки приёмника file — таблица, а не nil' },
        { {}, 'настройки приёмника file.path — непустая строка, а не nil' },
        {
            { path = '' },
            'настройки приёмника file.path — непустая строка, а не пустая',
        },
        {
            { path = 7 },
            'настройки приёмника file.path — непустая строка, а не число',
        },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(helper.refusal(file_sink.new, case[1]), helper.CALLER .. case[2], case[2])
    end
end

g.test_file_sink_refuses_what_it_does_not_know = function()
    t.assert_equals(
        helper.refusal(file_sink.new, { path = '/x', dir = '/var' }),
        helper.CALLER .. 'настройки приёмника file: ключа «dir» нет, есть name, path'
    )
    t.assert_equals(
        helper.refusal(file_sink.new, { path = '/x', name = 1 }),
        helper.CALLER .. 'настройки приёмника file.name — строка, а не число'
    )
end

g.test_file_sink_can_be_named = function()
    -- Имя приёмника едет в журнал при отказе: с двумя файлами иначе
    -- не понять, который из них молчит.
    t.assert_equals(file_sink.new({ path = '/x', name = 'дежурному' }).name, 'дежурному')
    t.assert_equals(file_sink.new({ path = '/x' }).name, 'file')
    t.assert_equals(file_sink.new({ path = '/x', name = box.NULL }).name, 'file', 'box.NULL — имени нет')
end

g.test_file_sink_keeps_the_path_it_was_given = function()
    -- Настройки берутся копией: правка таблицы вызывающего после сборки
    -- не уводит события в другой файл.
    local opts = { path = '/var/notify/app.jsonl' }
    local sink = file_sink.new(opts)

    opts.path = '/var/notify/other.jsonl'
    sink.send(event())

    t.assert_type(fake.contents['/var/notify/app.jsonl'], 'string')
    t.assert_equals(fake.contents['/var/notify/other.jsonl'], nil)
end

-- ── Чужая служба ─────────────────────────────────────────────────────

g.test_http_sink_posts_the_event = function()
    local sink = http_sink.new({ url = 'http://alerts.example/hook' })

    t.assert_equals(sink.send(event()), nil)
    t.assert_equals(#requests, 1)
    t.assert_equals(requests[1].method, 'POST')
    t.assert_equals(requests[1].url, 'http://alerts.example/hook')
    t.assert_equals(requests[1].opts.json.id, 'replication:instance:storage-001-a')
    t.assert_equals(requests[1].opts.headers['content-type'], 'application/json')
end

g.test_http_sink_waits_only_so_long = function()
    -- Отправка идёт в том же файбере, что и обход кластера: служба,
    -- отвечающая минуту, остановила бы диагностику на эту минуту.
    http_sink.new({ url = 'http://alerts.example/hook' }).send(event())

    t.assert_equals(requests[1].opts.timeout, 2)

    http_sink.new({ url = 'http://alerts.example/hook', timeout = 0.5 }).send(event())

    t.assert_equals(requests[2].opts.timeout, 0.5)
end

g.test_http_sink_carries_its_own_headers = function()
    -- Служба просит опознаться: заголовок приходит настройкой, а тип
    -- содержимого остаётся нашим.
    http_sink
        .new({
            url = 'http://alerts.example/hook',
            headers = { ['authorization'] = 'Bearer слово' },
        })
        .send(event())

    t.assert_equals(requests[1].opts.headers['authorization'], 'Bearer слово')
    t.assert_equals(requests[1].opts.headers['content-type'], 'application/json')
end

g.test_http_sink_keeps_a_content_type_it_was_given = function()
    -- Служба просит своё: наш тип содержимого — умолчание, а не догма.
    -- Имя сверяется без регистра: `Content-Type` рядом с нашим
    -- `content-type` уехал бы в клиент вдвоём с ним, и какой победит,
    -- решал бы порядок `pairs`.
    for _, name in ipairs({ 'content-type', 'Content-Type' }) do
        http_sink
            .new({
                url = 'http://alerts.example/hook',
                headers = { [name] = 'application/vnd.alerts+json' },
            })
            .send(event())
    end

    t.assert_equals(requests[1].opts.headers, { ['content-type'] = 'application/vnd.alerts+json' })
    t.assert_equals(requests[2].opts.headers, { ['content-type'] = 'application/vnd.alerts+json' })
end

g.test_http_sink_leaves_the_callers_headers_alone = function()
    -- Дописать тип тела в таблицу вызывающего значило бы поменять её
    -- у него на руках: та же таблица, отданная потом его собственному
    -- запросу, понесла бы туда наш тип.
    local headers = { ['Authorization'] = 'Bearer слово' }
    local sink = http_sink.new({ url = 'http://alerts.example/hook', headers = headers })

    sink.send(event())

    t.assert_equals(headers, { ['Authorization'] = 'Bearer слово' })

    -- И обратно: правка таблицы после сборки до приёмника не доезжает.
    headers['Authorization'] = 'Bearer другое'
    sink.send(event())

    t.assert_equals(requests[2].opts.headers, {
        ['authorization'] = 'Bearer слово',
        ['content-type'] = 'application/json',
    })
end

g.test_http_sink_takes_a_number_for_a_header_value = function()
    -- Число клиент приводит к строке сам: `x-count = 7` — обычное дело.
    http_sink.new({ url = 'http://alerts.example/hook', headers = { ['x-count'] = 7 } }).send(event())

    t.assert_equals(requests[1].opts.headers['x-count'], 7)
end

g.test_http_sink_refuses_wrong_settings_on_the_callers_line = function()
    -- Приёмник без адреса отказывал бы на каждом событии, строка в сроке
    -- ломала бы клиент на каждой отправке, а заголовок-таблицу клиент
    -- отверг бы тоже при отправке: видно всё это было бы только в журнале.
    local url = 'http://alerts.example/hook'
    local cases = {
        { nil, 'настройки приёмника http — таблица, а не nil' },
        { {}, 'настройки приёмника http.url — непустая строка, а не nil' },
        {
            { url = '' },
            'настройки приёмника http.url — непустая строка, а не пустая',
        },
        {
            { url = url, timeout = '2' },
            'настройки приёмника http.timeout — число больше 0, а не строка',
        },
        {
            { url = url, timeout = 0 },
            'настройки приёмника http.timeout — число больше 0, а не 0',
        },
        {
            { url = url, headers = 'json' },
            'настройки приёмника http.headers — таблица, а не строка',
        },
        {
            { url = url, headers = { 'Bearer слово' } },
            'имя заголовка в «настройки приёмника http.headers» — строка, а не число',
        },
        {
            { url = url, headers = { ['x-tags'] = { 'a' } } },
            'настройки приёмника http.headers.x-tags — строка или число, а не таблица',
        },
        {
            { url = url, name = false },
            'настройки приёмника http.name — строка, а не логическое значение',
        },
        {
            { url = url, retry = 3 },
            'настройки приёмника http: ключа «retry» нет, есть headers, name, timeout, url',
        },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(helper.refusal(http_sink.new, case[1]), helper.CALLER .. case[2], case[2])
    end

    t.assert_equals(requests, {}, 'негодный приёмник не отправил ничего')
end

g.test_http_sink_treats_null_settings_as_unset = function()
    -- `box.NULL` из YAML и JSON истинен в условии: оставленный, он ушёл бы
    -- в клиент сроком вместо умолчания.
    http_sink
        .new({ url = 'http://alerts.example/hook', timeout = box.NULL, headers = box.NULL, name = box.NULL })
        .send(event())

    t.assert_equals(requests[1].opts.timeout, 2)
    t.assert_equals(requests[1].opts.headers, { ['content-type'] = 'application/json' })
end

g.test_http_sink_accepts_any_two_hundred = function()
    -- Службы отвечают и 200, и 202, и 204: различать их незачем —
    -- важно, что событие принято.
    local sink = http_sink.new({ url = 'http://alerts.example/hook' })

    for _, status in ipairs({ 200, 202, 204, 299 }) do
        answer = { status = status }

        t.assert_equals(sink.send(event()), nil, tostring(status))
    end
end

g.test_http_sink_refuses_everything_outside_the_two_hundreds = function()
    -- Границы проверяются с обеих сторон: 199 — это ещё не приём,
    -- а 300 — уже перенаправление, и событие по нему никуда не ушло.
    local sink = http_sink.new({ url = 'http://alerts.example/hook' })

    for _, status in ipairs({ 199, 300, 301 }) do
        answer = { status = status }

        t.assert_str_contains(sink.send(event()), tostring(status), tostring(status))
    end
end

g.test_http_sink_needs_a_number_for_a_status = function()
    -- Служба ответила чем угодно: без числа в коде считать событие
    -- принятым нельзя.
    answer = { status = 'принято' }

    t.assert_str_contains(http_sink.new({ url = 'http://x' }).send(event()), 'принято')
end

g.test_http_sink_reports_a_refusal = function()
    answer = { status = 500 }

    local refusal = http_sink.new({ url = 'http://alerts.example/hook' }).send(event())

    t.assert_str_contains(refusal, '500')
end

g.test_http_sink_makes_a_real_client_by_default = function()
    -- Клиент настоящий, пока его не подменили: приёмник, у которого
    -- подмена стала умолчанием, в кластере не отправил бы ничего.
    http_sink._set_source(nil)

    local client = http_sink._default_client(2)
    local shown = client:status()

    t.assert_type(client.post, 'function')
    t.assert_equals(shown.timeout, 2, 'срок приёмника доходит до клиента')

    -- Повторы выключены намеренно, и это решение приёмника, а не клиента.
    -- Умолчание клиента разумно для запросов к чужому API, но здесь
    -- о живой находке напомнит срок напоминания, об ушедшей скажет отбой,
    -- а очередь неотправленного пережила бы перезапуск не лучше самой
    -- находки.
    t.assert_equals(shown.retry.attempts, 1, 'уведомление не повторяется клиентом')

    -- Переход по `Location` превратил бы POST в GET без тела, и событие,
    -- которого служба не получила, числилось бы доставленным.
    t.assert_equals(shown.max_redirects, 0, 'переход не проходится')
end

g.test_http_sink_can_be_named = function()
    t.assert_equals(http_sink.new({ url = 'http://x', name = 'дежурному' }).name, 'дежурному')
    t.assert_equals(http_sink.new({ url = 'http://x' }).name, 'http')
end

-- ── Письмо ───────────────────────────────────────────────────────────

--- Приёмник писем поверх подменённой отправки.
---
--- Отправка подменяется у самой почты, а не у приёмника: приёмник берёт
--- её сам, и проверять надо то письмо, которое ушло бы на сервер.
---@return table sink
---@return table[] sent Письма, ушедшие в подменённую отправку
local function mailing()
    local mail = testing.module('tnt.mail')
    local sent = {}

    mail.configure({ from = 'tarantool@example.org', smtp = { host = 'почтовик' } })

    mail.smtp.send = function(_, letter)
        table.insert(sent, letter)

        return true
    end

    return mail_sink.new({ to = 'duty@example.org' }), sent
end

g.test_mail_sink_sends_a_letter_per_event = function()
    -- Тот случай, ради которого уведомитель и писался: ночью в панель
    -- не смотрит никто, а письмо будит телефон.
    local sink, sent = mailing()

    t.assert_equals(sink.send(event()), nil)
    t.assert_equals(#sent, 1)

    local letter = helper.at(sent, 1)

    t.assert_equals(letter.to, 'duty@example.org')
    t.assert_str_contains(letter.subject, 'ТРЕВОГА')
    t.assert_str_contains(letter.subject, 'storage-001-a')
    t.assert_str_contains(letter.subject, 'реплика отстала')
    t.assert_str_contains(letter.text, 'Правило: replication')
end

g.test_mail_sink_names_the_state_in_the_subject = function()
    -- По уведомлению на экране блокировки человек должен понять,
    -- что случилось и насколько срочно, не открывая почту.
    local sink, sent = mailing()

    sink.send(event({ state = 'raised' }))
    sink.send(event({ state = 'resolved' }))
    sink.send(event({ state = 'reminded' }))
    sink.send(event({ state = 'неизвестно' }))

    t.assert_str_contains(helper.at(sent, 1).subject, 'ТРЕВОГА')
    t.assert_str_contains(helper.at(sent, 2).subject, 'отбой')
    t.assert_str_contains(helper.at(sent, 3).subject, 'всё ещё')
    t.assert_str_contains(helper.at(sent, 4).subject, 'неизвестно')
end

g.test_mail_sink_reports_a_refusal = function()
    local mail = testing.module('tnt.mail')

    mail.configure({ from = 'a@b', smtp = { host = 'почтовик' } })

    mail.smtp.send = function()
        return false, 'сервер ответил 550'
    end

    t.assert_str_contains(mail_sink.new({ to = 'duty@example.org' }).send(event()), '550')
end

g.test_mail_sink_refuses_wrong_settings_on_the_callers_line = function()
    -- У дежурного свой адрес, и получатели почты по умолчанию — не он:
    -- без своего получателя приёмник не собирается.
    local cases = {
        { nil, 'настройки приёмника mail — таблица, а не nil' },
        { {}, 'настройки приёмника mail.to — строка или таблица, а не nil' },
        {
            { to = 7 },
            'настройки приёмника mail.to — строка или таблица, а не 7',
        },
        {
            { to = 'a@b', from = true },
            'настройки приёмника mail.from — строка или таблица, а не true',
        },
        {
            { to = 'a@b', name = 1 },
            'настройки приёмника mail.name — строка, а не число',
        },
        {
            { to = 'a@b', cc = 'c@d' },
            'настройки приёмника mail: ключа «cc» нет, есть from, name, to',
        },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(helper.refusal(mail_sink.new, case[1]), helper.CALLER .. case[2], case[2])
    end
end

g.test_mail_sink_takes_the_addresses_as_the_mail_does = function()
    -- Адрес — как его понимает почта: строка, таблица с именем или список.
    local sink, sent = mailing()
    local named = { address = 'duty@example.org', name = 'Дежурный' }

    sink.send(event())
    mail_sink.new({ to = { 'duty@example.org', named }, from = named }).send(event())

    t.assert_equals(
        helper.at(sent, 1).from,
        'tarantool@example.org',
        'отправитель по умолчанию — у почты'
    )
    t.assert_equals(helper.at(sent, 2).to, { 'duty@example.org', named })
    t.assert_equals(helper.at(sent, 2).from, named)
end

g.test_mail_sink_treats_null_settings_as_unset = function()
    -- `box.NULL` из YAML и JSON — не отправитель: оставленный, он ушёл бы
    -- в письмо вместо отправителя почты по умолчанию.
    local sink, sent = mailing()

    sink.send(event())
    mail_sink.new({ to = 'duty@example.org', from = box.NULL, name = box.NULL }).send(event())

    t.assert_equals(helper.at(sent, 2).from, 'tarantool@example.org')
    t.assert_equals(mail_sink.new({ to = 'duty@example.org', name = box.NULL }).name, 'mail')
end

g.test_mail_sink_can_be_named = function()
    t.assert_equals(mail_sink.new({ to = 'a@b', name = 'дежурному' }).name, 'дежурному')
    t.assert_equals(mail_sink.new({ to = 'a@b' }).name, 'mail')
end

g.test_finding_about_a_replicaset_names_it = function()
    -- Находка бывает не об узле, а о репликасете или кластере целиком:
    -- тема письма обязана называть того, о ком речь.
    local sink, sent = mailing()
    local about_replicaset = event({ replicaset = 'storage-001' })

    about_replicaset.instance = nil

    sink.send(about_replicaset)

    local about_cluster = event()

    about_cluster.instance = nil
    about_cluster.replicaset = nil

    sink.send(about_cluster)

    t.assert_str_contains(helper.at(sent, 1).subject, 'storage-001')
    t.assert_str_contains(helper.at(sent, 2).subject, 'кластер')
end

g.test_letter_names_the_node_only_when_there_is_one = function()
    -- В теле письма перечислено всё, что известно о находке. Узел
    -- и репликасет — только те, что в находке есть: строка «Узел: nil»
    -- в письме дежурному не помогает никому.
    local sink, sent = mailing()
    local about_cluster = event()

    about_cluster.instance = nil
    about_cluster.replicaset = nil

    sink.send(event({ replicaset = 'storage-001' }))
    sink.send(about_cluster)

    local about_node = helper.at(sent, 1).text

    t.assert_str_contains(about_node, 'Узел: storage-001-a')
    t.assert_str_contains(about_node, 'Репликасет: storage-001')

    local whole = helper.at(sent, 2).text

    t.assert_equals(whole:find('Узел:'), nil)
    t.assert_equals(whole:find('Репликасет:'), nil)
end
