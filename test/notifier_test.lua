--- Тесты уведомлений: появление находки, отбой, напоминание и пороги.

local t = require('luatest')

local g = t.group('tnt.notifier')

local helper = dofile('test/helper.lua')
local testing = helper.testing

--- Уведомитель с приёмниками и тем, что они берут при загрузке.
local Module = helper.MODULES

---@type any
local notifier

--- Который час по мнению уведомителя.
---
--- Одно число на обои часы: сколько прошло по стенным, столько же и по
--- монотонным. Разводит их только `shift`.
---@type number
local now

--- На сколько перевели стенные часы: монотонные перевода не видят.
---@type number
local shift

--- Что ушло наружу.
---@type table[]
local sent

--- Чем отвечает приёмник: пустота — принял.
---@type any
local refusal

--- Приёмник, который всё запоминает.
---@return table
local function catcher()
    return {
        name = 'ловец',

        send = function(event)
            table.insert(sent, event)

            return refusal
        end,
    }
end

--- Находка диагностики.
---@param overrides table|nil
---@return table
local function finding(overrides)
    local entry = {
        id = 'replication:instance:storage-001-a',
        rule = 'replication',
        scope = 'instance',
        instance = 'storage-001-a',
        replicaset = 'storage-001',
        severity = 'critical',
        message = 'реплика отстала',
    }

    for key, value in pairs(overrides or {}) do
        entry[key] = value
    end

    return entry
end

--- Событие под указанным номером; его отсутствие — ошибка самого теста.
---@param index integer
---@return any
local function at(index)
    return (assert(sent[index], ('события №%d нет'):format(index)))
end

--- Состояния отправленных событий по порядку.
---@return string[]
local function states()
    local out = {}

    for _, event in ipairs(sent) do
        table.insert(out, event.state)
    end

    return out
end

--- Двойник встроенного реестра проверок готовности.
---
--- Помнит заведённые проверки и порядок обращений: второй проверки
--- с тем же именем не принимает, как и настоящий, — иначе проверка
--- перезаведения ничего не доказывает.
---@type any
local registry

--- Кого уведомитель подписал на перемены конфигурации.
---@type any
local watched

--- Средства уведомителя: часы теста, двойник реестра и подписки.
---@return table
local function tools()
    return {
        now = function()
            return now + shift
        end,
        monotonic = function()
            return now - 1789036300
        end,
        registry = function()
            return registry
        end,
        watch = function(key, handler)
            watched = { key = key, handler = handler, unregistered = false }

            return {
                unregister = function()
                    watched.unregistered = true
                end,
            }
        end,
    }
end

g.before_each(function()
    now = 1789041300
    shift = 0
    sent = {}
    refusal = nil
    watched = nil

    registry = {
        checks = {},
        touched = {},
        refusal = nil,

        add_health_check = function(name, check)
            table.insert(registry.touched, 'заводит ' .. name)

            if registry.refusal ~= nil then
                return false, registry.refusal
            end

            if registry.checks[name] ~= nil then
                return false, ('health check %q already exists'):format(name)
            end

            registry.checks[name] = check

            return true
        end,

        remove_health_check = function(name, opts)
            table.insert(registry.touched, 'снимает ' .. name)
            t.assert_equals(opts, { if_exists = true }, 'снимать молча и то, чего нет')
            registry.checks[name] = nil

            return true
        end,
    }

    notifier = testing.load_sources(Module, 'tnt.notifier')
    notifier._set_source(tools())

    notifier.configure({ sinks = { catcher() } })
end)

g.after_each(function()
    notifier._set_source(nil)
    testing.unload_sources(Module)
end)

g.test_new_finding_is_told_about = function()
    notifier.on_issues({ finding() })

    t.assert_equals(#sent, 1)
    t.assert_equals(at(1).state, notifier.RAISED)
    t.assert_equals(at(1).id, 'replication:instance:storage-001-a')
    t.assert_equals(at(1).severity, 'critical')
    t.assert_equals(at(1).instance, 'storage-001-a')
    t.assert_equals(at(1).replicaset, 'storage-001')
    t.assert_equals(at(1).rule, 'replication')
    t.assert_equals(at(1).message, 'реплика отстала')
    t.assert_equals(at(1).at, now)
end

g.test_same_finding_is_not_told_about_twice = function()
    -- Обход идёт раз в секунду: за ночь одна незакрытая находка
    -- превратилась бы в тридцать тысяч писем.
    for _ = 1, 5 do
        notifier.on_issues({ finding() })
        now = now + 1
    end

    t.assert_equals(#sent, 1)
end

g.test_gone_finding_gets_its_all_clear = function()
    -- Человек, получивший ночью тревогу и не получивший отбоя, поедет
    -- в офис.
    notifier.on_issues({ finding() })
    notifier.on_issues({})

    t.assert_equals(states(), { notifier.RAISED, notifier.RESOLVED })
    t.assert_equals(at(2).message, 'реплика отстала', 'отбой несёт ту же находку')
end

g.test_all_clear_can_be_switched_off = function()
    notifier.configure({ sinks = { catcher() }, resolve = false })

    notifier.on_issues({ finding() })
    notifier.on_issues({})

    t.assert_equals(states(), { notifier.RAISED })
end

g.test_finding_that_returns_is_told_about_again = function()
    -- Ушла и вернулась — это новая беда, а не продолжение старой.
    notifier.on_issues({ finding() })
    notifier.on_issues({})
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED, notifier.RESOLVED, notifier.RAISED })
end

g.test_long_living_finding_reminds_about_itself = function()
    -- Реже — и находка выглядит забытой, чаще — и напоминания сами
    -- становятся шумом, от которого отписываются.
    notifier.on_issues({ finding() })

    now = now + 3599
    notifier.on_issues({ finding() })

    t.assert_equals(#sent, 1, 'час ещё не прошёл')

    now = now + 1
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED, notifier.REMINDED })
end

g.test_reminder_is_timed_by_the_monotonic_clock_and_not_by_the_date = function()
    -- Стенные часы перевели: сперва на два часа вперёд, потом на три назад.
    -- По датам напоминание ушло бы сразу, а после второго перевода молчало
    -- бы лишний час. По монотонным часам прошло пять минут, и напоминать
    -- рано; через час — пора, и дата в событии та, что показывают стенные.
    notifier.on_issues({ finding() })

    shift = 7200
    now = now + 300
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED })

    shift = -3600
    now = now + 3300
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED, notifier.REMINDED })
    t.assert_equals(at(2).at, now - 3600)
end

g.test_reminder_interval_is_configurable = function()
    notifier.configure({ sinks = { catcher() }, repeat_after = 60 })

    notifier.on_issues({ finding() })
    now = now + 60
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED, notifier.REMINDED })
end

g.test_threshold_outside_the_dictionary_lets_everyone_through = function()
    -- Порог словом, которого нет в словаре, никого не отсекает: молчать
    -- обо всём из-за опечатки в настройке хуже, чем шуметь.
    notifier.configure({ sinks = { catcher() }, min_severity = 'наблюдение' })

    notifier.on_issues({ finding({ severity = 'warning' }) })

    t.assert_equals(#sent, 1)
end

g.test_loudest_finding_passes_its_own_threshold = function()
    -- Порог — это «от и громче»: тревога при пороге «тревога» проходит.
    notifier.configure({ sinks = { catcher() }, min_severity = 'critical' })

    notifier.on_issues({ finding({ severity = 'critical' }) })

    t.assert_equals(#sent, 1)
end

g.test_reminder_comes_even_after_a_long_silence = function()
    -- Срок — это «через столько и позже», а не «ровно через столько»:
    -- обход мог не дойти до находки несколько часов.
    notifier.on_issues({ finding() })

    now = now + 7200
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED, notifier.REMINDED })
end

g.test_quiet_findings_are_skipped = function()
    -- Порог задаётся словом, а сравниваются веса: «critical» меньше
    -- «warning» по алфавиту, и сравнение слов однажды пропустило бы
    -- тревогу, отбросив предупреждение.
    notifier.configure({ sinks = { catcher() }, min_severity = 'critical' })

    notifier.on_issues({ finding({ severity = 'warning', id = 'тихая' }), finding() })

    t.assert_equals(#sent, 1)
    t.assert_equals(at(1).severity, 'critical')
end

g.test_unknown_severity_is_too_quiet_to_send = function()
    -- Слово не из словаря — это не «самая страшная беда»: правило, чей
    -- уровень не разобран, не должно будить человека.
    notifier.on_issues({ finding({ severity = 'любопытно' }) })

    t.assert_equals(sent, {})
end

g.test_finding_without_an_identifier_is_skipped = function()
    -- Без опознавателя находку не отличить от такой же соседней:
    -- напоминания и отбои по ней ушли бы наугад.
    --
    -- Поле убирается отдельной строкой: `nil` в таблице правок ключа
    -- не создаёт, и находка осталась бы с опознавателем из умолчания.
    local nameless = finding()

    nameless.id = nil

    notifier.on_issues({ nameless })

    t.assert_equals(sent, {})
    t.assert_equals(notifier.size(), 0)
end

g.test_failing_sink_does_not_stop_the_others = function()
    -- Приёмники не связаны между собой ничем, кроме общего списка
    -- находок: общая остановка из-за одного означала бы, что худший
    -- решает за всех.
    local journal = testing.capture_log()

    journal.forget()

    notifier.configure({
        sinks = {
            {
                name = 'падучий',
                send = function()
                    error('служба не отвечает')
                end,
            },
            catcher(),
        },
    })

    notifier.on_issues({ finding() })

    t.assert_equals(#sent, 1)
    t.assert_equals(journal.logged('уведомление не доставлено'), true)
end

g.test_refusing_sink_is_written_down = function()
    -- Приёмник вправе отказать словами, а не исключением: молчать
    -- об этом нельзя — уведомление не дошло.
    local journal = testing.capture_log()

    journal.forget()
    refusal = 'служба ответила 500'

    notifier.on_issues({ finding() })

    t.assert_equals(journal.logged('уведомление не доставлено'), true)
end

--- Список находок с разными опознавателями.
---@param count integer
---@return table[]
local function many(count)
    local issues = {}

    for index = 1, count do
        table.insert(issues, finding({ id = 'находка-' .. index }))
    end

    return issues
end

g.test_memory_is_bounded = function()
    -- Список находок на кластере в сотню узлов растёт быстрее, чем
    -- кажется: без потолка он растёт вместе с памятью узла.
    local journal = testing.capture_log()

    notifier.configure({ sinks = { catcher() }, capacity = 3 })

    journal.forget()
    notifier.on_issues(many(3))

    t.assert_equals(notifier.size(), 3, 'ровно потолок — это ещё не переполнение')
    t.assert_equals(journal.logged('больше, чем помещается'), false)

    notifier.on_issues(many(4))

    t.assert_equals(notifier.size(), 0, 'переполнение забывает всё разом')
    t.assert_equals(journal.logged('больше, чем помещается'), true)
end

g.test_default_capacity_is_the_one_declared = function()
    -- Потолок по умолчанию виден только счётом: настройка его меняет,
    -- а умолчание проверить иначе нечем.
    notifier.configure({ sinks = { catcher() } })
    notifier.on_issues(many(1024))

    t.assert_equals(notifier.size(), 1024, 'тысяча с четвертью помещается')

    notifier.on_issues(many(1025))

    t.assert_equals(notifier.size(), 0, 'а одна сверх того — уже нет')
end

g.test_sink_that_took_the_event_is_not_complained_about = function()
    -- Приёмник, принявший событие, молчит — и уведомитель молчит тоже:
    -- запись в журнал на каждое доставленное уведомление сделала бы
    -- журнал вторым каналом уведомлений.
    local journal = testing.capture_log()

    journal.forget()
    notifier.on_issues({ finding() })

    t.assert_equals(journal.logged('уведомление не доставлено'), false)
end

g.test_status_tells_what_is_set_up = function()
    notifier.configure({
        sinks = { catcher() },
        min_severity = 'critical',
        repeat_after = 120,
        resolve = false,
    })

    notifier.on_issues({ finding() })

    t.assert_equals(notifier.status(), {
        sinks = { 'ловец' },
        min_severity = 'critical',
        repeat_after = 120,
        resolve = false,
        known = 1,
    })
end

g.test_settings_fall_back_to_defaults = function()
    notifier.configure(nil)

    t.assert_equals(notifier.status(), {
        sinks = {},
        min_severity = 'warning',
        repeat_after = 3600,
        resolve = true,
        known = 0,
    })

    notifier.configure({})

    t.assert_equals(
        notifier.status().repeat_after,
        3600,
        'пустые настройки — те же умолчания'
    )
end

g.test_memory_is_forgotten_on_demand = function()
    notifier.on_issues({ finding() })
    notifier.forget()
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED, notifier.RAISED })
end

g.test_no_findings_no_noise = function()
    notifier.on_issues({})
    notifier.on_issues(nil)

    t.assert_equals(sent, {})
end

g.test_mail_sink_is_offered_when_the_package_is_there = function()
    -- Пакет почты есть не в каждом кластере, и уведомитель обязан
    -- работать без него. Но там, где он есть, письма должны быть
    -- под рукой — без второго require у вызывающего.
    t.assert_type(notifier.mail, 'table')
    t.assert_type(notifier.mail.new, 'function')
end

-- ── Проверка настроек ───────────────────────────────────────────────

--- Бросок настройки, позванной из чужого кода: место и текст целиком.
---@param opts any
---@return string
local function refused(opts)
    return helper.refusal(notifier.configure, opts)
end

--- Что показывает состояние при настройках по умолчанию.
local DEFAULT_STATUS = {
    sinks = {},
    min_severity = 'warning',
    repeat_after = 3600,
    resolve = true,
    known = 0,
}

g.test_settings_that_are_not_a_table_are_refused_on_the_callers_line = function()
    -- Хук диагностики зовёт уведомитель под `pcall`: негодная настройка,
    -- дошедшая до обхода, осталась бы записью в журнале, а уведомления
    -- перестали бы уходить. Поэтому бросок — там, где настраивали.
    t.assert_equals(
        refused('warning'),
        helper.CALLER .. 'настройки уведомителя — таблица, а не строка'
    )
end

g.test_unknown_setting_is_refused = function()
    -- Опечатка в имени настройки иначе молча оставила бы умолчание,
    -- и напоминание так и приходило бы раз в час.
    t.assert_equals(
        refused({ repeat_afer = 60 }),
        helper.CALLER
            .. 'настройки уведомителя: ключа «repeat_afer» нет, '
            .. 'есть capacity, min_severity, repeat_after, resolve, sinks'
    )
end

g.test_each_setting_of_a_wrong_kind_is_refused = function()
    -- Строка в сроке роняла второй обход с той же находкой, строка
    -- в потолке — каждый обход, а слово в `resolve` истинно и при «no».
    local cases = {
        {
            { min_severity = 2 },
            'настройки уведомителя.min_severity — строка, а не число',
        },
        {
            { repeat_after = '60' },
            'настройки уведомителя.repeat_after — число больше 0, а не строка',
        },
        {
            { capacity = '10' },
            'настройки уведомителя.capacity — целое число, а не строка',
        },
        {
            { capacity = 1.5 },
            'настройки уведомителя.capacity — целое число, а не 1.5',
        },
        {
            { resolve = 'no' },
            'настройки уведомителя.resolve — логическое значение, а не строка',
        },
        { { sinks = 'log' }, 'настройки уведомителя.sinks — массив, а не строка' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(refused(case[1]), helper.CALLER .. case[2], case[2])
    end
end

g.test_reminder_interval_must_be_above_zero = function()
    -- При нуле напоминание уходило бы на каждом обходе — тем самым шумом,
    -- от которого уведомитель и спасает; NaN не напомнил бы никогда.
    for _, interval in ipairs({ 0, -60, 0 / 0 }) do
        local shown = interval == interval and tostring(interval) or 'NaN'

        t.assert_equals(
            refused({ repeat_after = interval }),
            helper.CALLER
                .. 'настройки уведомителя.repeat_after — число больше 0, а не '
                .. shown,
            shown
        )
    end

    notifier.configure({ sinks = { catcher() }, repeat_after = 0.5 })

    t.assert_equals(notifier.status().repeat_after, 0.5, 'доля секунды — тоже срок')
end

g.test_capacity_must_be_above_zero = function()
    -- Потолок в ноль забывал бы всё на каждом обходе, и каждая живая
    -- находка каждый обход была бы новой тревогой.
    for _, capacity in ipairs({ 0, -1 }) do
        t.assert_equals(
            refused({ capacity = capacity }),
            helper.CALLER
                .. 'настройки уведомителя.capacity — число больше 0, а не '
                .. capacity
        )
    end
end

g.test_single_sink_without_a_list_is_refused = function()
    -- Таблицу приёмника обходили бы как пустой список: уведомления молча
    -- не уходили бы никуда.
    local sink = catcher()

    t.assert_equals(
        refused({ sinks = sink }),
        helper.CALLER
            .. ('настройки уведомителя.sinks — массив, а не таблица с ключом «%s»'):format(
                next(sink)
            )
    )
end

g.test_sink_needs_a_send_and_a_name = function()
    -- Номер в отказе — тот, что у приёмника в списке: с двумя
    -- приёмниками иначе не понять, который из них чинить.
    local cases = {
        { { 'log' }, 'настройки уведомителя.sinks[1] — таблица, а не строка' },
        {
            { catcher(), { name = 'немой' } },
            'настройки уведомителя.sinks[2].send — функция или вызываемая таблица, а не nil',
        },
        {
            { { send = catcher().send } },
            'настройки уведомителя.sinks[1].name — строка, а не nil',
        },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(refused({ sinks = case[1] }), helper.CALLER .. case[2], case[2])
    end
end

g.test_sink_may_send_through_a_callable_table = function()
    -- Двойник и обработчик с состоянием — это часто таблица с `__call`,
    -- и вызывается она так же, как функция.
    local send = setmetatable({}, {
        __call = function(_, event)
            table.insert(sent, event)
        end,
    })

    notifier.configure({ sinks = { { name = 'вызываемый', send = send } } })
    notifier.on_issues({ finding() })

    t.assert_equals(states(), { notifier.RAISED })
end

g.test_refused_settings_leave_the_previous_ones = function()
    -- Всё проверяется раньше, чем меняется: брошенная посреди настройки,
    -- она оставила бы уведомитель наполовину перенастроенным.
    notifier.configure({ sinks = { catcher() }, repeat_after = 120 })

    refused({ sinks = { catcher(), { name = 'немой' } }, repeat_after = 60 })
    refused({ repeat_after = 60, capacity = 0 })

    t.assert_equals(notifier.status().repeat_after, 120)
    t.assert_equals(notifier.status().sinks, { 'ловец' })
end

g.test_null_setting_is_no_setting = function()
    -- `box.NULL` — так приходит пустое значение из YAML и JSON. В условии
    -- он истинен, и оставленный в настройках он стал бы порогом, сроком
    -- и потолком вместо умолчаний; с потолком обход падал бы на сравнении.
    notifier.configure({
        sinks = box.NULL,
        min_severity = box.NULL,
        repeat_after = box.NULL,
        capacity = box.NULL,
        resolve = box.NULL,
    })
    notifier.on_issues({ finding() })

    t.assert_equals(notifier.status(), {
        sinks = {},
        min_severity = 'warning',
        repeat_after = 3600,
        resolve = true,
        known = 1,
    })

    notifier.forget()
    notifier.configure(box.NULL)

    t.assert_equals(notifier.status(), DEFAULT_STATUS)
end

g.test_sinks_are_taken_as_they_were_at_configuration = function()
    -- Приёмник, дописанный в список после настройки, прошёл бы мимо
    -- проверки.
    local sinks = { catcher() }

    notifier.configure({ sinks = sinks })
    table.insert(sinks, { name = 'подброшенный', send = catcher().send })
    notifier.on_issues({ finding() })

    t.assert_equals(notifier.status().sinks, { 'ловец' })
    t.assert_equals(states(), { notifier.RAISED }, 'событие ушло одному приёмнику')
end

-- ── Находки во встроенном реестре проверок ──────────────────────────

--- Что ответили заведённые проверки: имя → исход и причина.
---@return table<string, table>
local function verdicts()
    local out = {}

    for name, check in pairs(registry.checks) do
        out[name] = { check() }
    end

    return out
end

g.test_findings_stay_out_of_the_registry_unless_asked = function()
    -- Проверка готовности — решение приложения: узел с отказами в реестре
    -- отвечает «не готов» в box.info.health, и молча делать это нельзя.
    registry = nil

    notifier.on_issues({ finding() })
    notifier.forget()

    t.assert_equals(watched, nil)
end

g.test_known_findings_are_registered_at_once = function()
    notifier.on_issues({ finding() })
    notifier.publish_health_checks()

    t.assert_equals(verdicts(), {
        ['cluster.findings.replication:instance:storage-001-a'] = { false, 'critical: реплика отстала' },
    })
end

g.test_registry_follows_the_findings = function()
    notifier.publish_health_checks()

    notifier.on_issues({ finding() })
    t.assert_equals(verdicts(), {
        ['cluster.findings.replication:instance:storage-001-a'] = { false, 'critical: реплика отстала' },
    })

    -- Долгоживущая находка говорит последнее: предупреждение с вчерашним
    -- сообщением хуже, чем никакое.
    notifier.on_issues({ finding({ message = 'реплика отстала на час', severity = 'warning' }) })
    t.assert_equals(verdicts(), {
        ['cluster.findings.replication:instance:storage-001-a'] = {
            false,
            'warning: реплика отстала на час',
        },
    })

    registry.touched = {}
    notifier.on_issues({})

    t.assert_equals(verdicts(), {})
    t.assert_equals(registry.touched, { 'снимает cluster.findings.replication:instance:storage-001-a' })
end

g.test_registered_finding_is_not_registered_again_each_round = function()
    notifier.publish_health_checks()
    notifier.on_issues({ finding() })

    registry.touched = {}
    notifier.on_issues({ finding() })

    t.assert_equals(registry.touched, {})
end

g.test_quiet_findings_stay_out_of_the_registry = function()
    notifier.configure({ sinks = { catcher() }, min_severity = 'critical' })
    notifier.publish_health_checks()
    notifier.on_issues({ finding({ severity = 'warning' }) })

    t.assert_equals(verdicts(), {})
end

g.test_configuration_findings_are_not_echoed = function()
    -- Находка о конфигурации пересказывает предупреждения узла: о своём
    -- узле — наши же, и сообщение росло бы с каждым обходом без конца.
    notifier.publish_health_checks()
    notifier.on_issues({
        finding({ id = 'configuration:instance:panel-001-a', rule = 'configuration' }),
        finding({ id = 'disk:instance:storage-001-b', rule = 'disk' }),
    })

    t.assert_equals(verdicts(), {
        ['cluster.findings.disk:instance:storage-001-b'] = { false, 'critical: реплика отстала' },
    })
end

g.test_stale_check_of_the_same_name_is_replaced = function()
    -- Проверка с тем же именем могла остаться от перезагруженного модуля:
    -- она читала бы его память, а реестр второй такой не принял бы.
    registry.checks['cluster.findings.replication:instance:storage-001-a'] = function()
        return true
    end

    notifier.on_issues({ finding() })
    notifier.publish_health_checks()

    t.assert_equals(verdicts(), {
        ['cluster.findings.replication:instance:storage-001-a'] = { false, 'critical: реплика отстала' },
    })
end

g.test_refused_registration_is_written_down_and_retried = function()
    local journal = testing.capture_log()

    journal.forget()
    registry.refusal = 'реестр переполнен'
    notifier.publish_health_checks()
    notifier.on_issues({ finding() })

    t.assert_equals(
        journal.logged('находка не заведена проверкой готовности'),
        true
    )
    t.assert_equals(journal.logged('реестр переполнен'), true)

    registry.refusal = nil
    notifier.on_issues({ finding() })

    t.assert_equals(verdicts(), {
        ['cluster.findings.replication:instance:storage-001-a'] = { false, 'critical: реплика отстала' },
    })
end

g.test_forgotten_findings_leave_the_registry = function()
    notifier.publish_health_checks()
    notifier.on_issues({ finding() })

    local check = registry.checks['cluster.findings.replication:instance:storage-001-a']

    notifier.forget()

    t.assert_equals(verdicts(), {})

    -- Проверка, которую ядро успело позвать после забвения, уже не отказ.
    t.assert_equals({ check() }, { true })
end

g.test_overflow_clears_the_registry_too = function()
    notifier.configure({ sinks = { catcher() }, capacity = 1 })
    notifier.publish_health_checks()
    notifier.on_issues(many(2))

    t.assert_equals(verdicts(), {})
end

g.test_withdrawal_removes_checks_and_stops_registering = function()
    notifier.publish_health_checks()
    notifier.on_issues({ finding() })
    notifier.withdraw_health_checks()

    t.assert_equals(verdicts(), {})
    t.assert_equals(watched.unregistered, true)

    notifier.on_issues({ finding({ id = 'disk:instance:storage-001-b' }) })

    t.assert_equals(verdicts(), {})

    -- Снятие без проведения молчит: снимать нечего и не с чего падать.
    notifier.withdraw_health_checks()
end

g.test_configuration_change_registers_checks_anew = function()
    -- Перечитывание в 3.8.0 стирает доску предупреждений, а реестр помнит,
    -- что предупреждение поднято: заведённая заново проверка поднимает его
    -- с нуля.
    notifier.publish_health_checks()
    notifier.publish_health_checks()
    notifier.on_issues({ finding() })

    t.assert_equals(watched.key, 'config.info')

    local handler = watched.handler

    watched = nil
    registry.touched = {}
    handler('config.info', { status = 'ready' })

    t.assert_equals(registry.touched, {
        'снимает cluster.findings.replication:instance:storage-001-a',
        'снимает cluster.findings.replication:instance:storage-001-a',
        'заводит cluster.findings.replication:instance:storage-001-a',
    })
    t.assert_equals(
        watched,
        nil,
        'повторное проведение не подписывается второй раз'
    )
end

g.test_real_registry_evaluates_the_findings = function()
    -- Настоящий реестр сверяет переключения файбера до и после проверки:
    -- уступившая проверка отказала бы словами «health check must not yield».
    notifier._set_source(nil)
    notifier.configure({ sinks = { catcher() } })
    notifier.on_issues({ finding() })
    notifier.publish_health_checks()

    -- Внутренний модуль ядра: в аннотациях Tarantool его нет.
    ---@diagnostic disable-next-line: unresolved-require
    local kernel = require('internal.healthcheck')
    local registered = kernel.readiness().checks

    notifier.withdraw_health_checks()

    local withdrawn = kernel.readiness().checks

    t.assert_equals(
        registered['cluster.findings.replication:instance:storage-001-a'].reason,
        'critical: реплика отстала'
    )
    t.assert_equals(withdrawn['cluster.findings.replication:instance:storage-001-a'], nil)
end
