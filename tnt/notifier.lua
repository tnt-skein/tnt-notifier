--- Уведомления о находках.
---
--- Диагностика знает о кластере всё, что нужно, и рассказывает об этом
--- тому, кто спросит. Беда в том, что ночью не спрашивает никто: находка
--- живёт в панели, а человек спит — и узнаёт о ней утром, вместе
--- с последствиями.
---
--- Уведомитель переворачивает это: не человек ходит за находками,
--- а находки идут к человеку. Подписывается он на тот же хук, которым
--- диагностика отдаёт разбор каждого обхода, и ничего не опрашивает сам.
---
--- Слать каждую находку каждый обход нельзя — обход идёт раз в секунду,
--- и за ночь одна незакрытая находка превратится в тридцать тысяч писем.
--- Поэтому уведомление уходит на перемену состояния: находка появилась,
--- находка ушла. Долгоживущая напоминает о себе не чаще заданного срока —
--- ровно чтобы не выглядеть забытой.
---
--- Уход находки — событие не менее важное, чем появление. Человек,
--- получивший ночью тревогу и не получивший отбоя, поедет в офис.
---
--- Отказ приёмника не роняет обход и не мешает остальным приёмникам:
--- они не связаны между собой ничем, кроме общего списка находок,
--- и общая остановка из-за одного означала бы, что худший решает за всех.
---
--- Включение выглядит так:
---
---     local notifier = require('tnt.notifier')
---
---     notifier.configure({
---         sinks = { notifier.log.new(), notifier.http.new({ url = '...' }) },
---         min_severity = 'warning',
---     })
---
---     cluster.configure({ on_issues = notifier.on_issues })
---
--- Находки можно провести и через встроенный реестр проверок готовности:
---
---     notifier.publish_health_checks()
---
--- Каждая находка тогда — проверка `cluster.findings.<опознаватель>`,
--- её отказ — предупреждение конфигурации в `config:info().alerts`,
--- а их число — в `tnt_config_alerts`. Там, где настроен Prometheus,
--- тревоги работают без единого приёмника. Публичного способа поднять
--- своё предупреждение у ядра нет, эта дверь единственная.
---
--- Включают это на узле уведомителя, а не на всех, и не даром: встроенная
--- готовность такого узла (`box.info.health`) из-за беды соседа — «не
--- готов». Проба `/health/ready` пакета `tnt-health` проверок `cluster.*`
--- не спрашивает и узел с балансировки не снимает, но всякий, кто читает
--- `box.info.health` сам, увидит неготовый узел.

local clock = require('tnt.clock')
local external = require('tnt.external')
local must = require('tnt.must')

local checked = require('tnt.notifier.settings').checked
local log = require('tnt.log').new('tnt.notifier')

local Module = {}

--- Части: доступны тем, кто собирает своё поведение.
Module.log = require('tnt.notifier.sink.log')
Module.file = require('tnt.notifier.sink.file')
Module.http = require('tnt.notifier.sink.http')

--- Приёмник писем отдельно: пакет почты есть не в каждом кластере,
--- и уведомитель обязан работать без него.
Module.mail = nil

do
    local available, sink = pcall(require, 'tnt.notifier.sink.mail')

    if available then
        Module.mail = sink
    end
end

--- Находка появилась.
Module.RAISED = 'raised'

--- Находка ушла.
Module.RESOLVED = 'resolved'

--- Находка всё ещё здесь.
Module.REMINDED = 'reminded'

--- Уровни от тихого к громкому.
---
--- Порядком, а не числами: числа пришлось бы держать согласованными
--- между собой руками, а порядок и есть то единственное, что о них
--- нужно знать. Сравнивать сами слова нельзя — «critical» меньше
--- «warning» по алфавиту.
local LEVELS = { 'warning', 'critical' }

--- Насколько серьёзен уровень: чем больше, тем хуже.
---@type table<string, integer>
local WEIGHT = {}

for index, name in ipairs(LEVELS) do
    WEIGHT[name] = index
end

--- Через сколько напоминать о находке, которая никуда не делась.
---
--- Час: реже — и находка выглядит забытой, чаще — и напоминания сами
--- становятся шумом, от которого отписываются.
local DEFAULT_REPEAT_AFTER = 3600

--- Сколько находок помнить.
---
--- Потолок нужен не от злого умысла, а от кластера на сотню узлов
--- с десятком правил: список находок там растёт быстрее, чем кажется.
local DEFAULT_CAPACITY = 1024

--- Настройки. Заполняются вызовом `configure` в конце файла: держать
--- умолчания в двух местах значит однажды развести их между собой.
---@type any
local settings

---@class TntNotifierKnown
---@field finding table Сама находка, как её видели в последний раз
---@field told_at number Когда о ней рассказывали, по монотонным часам

--- Что мы уже рассказывали: опознаватель находки → когда.
---@type table<string, TntNotifierKnown>
local known = {}

--- Внешние средства: часы.
---
--- Часов двое. Стенные ставят дату в событие: её читает человек.
--- Срок напоминания — длительность, и меряется он монотонными: перевод
--- стенных часов назад заглушил бы напоминания на всё время перевода,
--- вперёд — выпустил бы их разом. Память о рассказанном живёт в процессе,
--- поэтому монотонная отметка в ней сравнима.
local source = external.install(Module, {
    now = clock.realtime,
    monotonic = clock.monotonic,

    -- Встроенный реестр проверок готовности: спрашивается при надобности,
    -- чтобы уведомитель без реестра хотя бы загружался.
    --
    -- Модуль внутренний, и в аннотациях Tarantool его нет. Пользоваться
    -- им — осознанное решение: публичного способа поднять своё
    -- предупреждение конфигурации у ядра нет, эта дверь единственная.
    registry = function()
        ---@diagnostic disable-next-line: unresolved-require
        return require('internal.healthcheck')
    end,

    watch = function(key, handler)
        return box.watch(key, handler)
    end,
})

--- С чего начинаются имена проверок о находках.
---
--- С `cluster.`: так их узнаёт проба готовности узла (`tnt.health`) и не
--- снимает с балансировки узел, на котором живёт уведомитель, за беды
--- соседей.
Module.HEALTH_CHECK_PREFIX = 'cluster.findings.'

--- Правила, чьи находки в реестр не идут.
---
--- Находка `configuration` пересказывает предупреждения конфигурации узла.
--- О чужом узле она и так предупреждение — там, где случилась. О своём —
--- она пересказала бы наши же предупреждения, из них родилась бы новая
--- находка, и сообщение росло бы с каждым обходом без конца.
---@type table<string, boolean>
local ECHOES = {
    configuration = true,
}

--- Проводятся ли находки через реестр.
local announcing = false

--- Какие проверки заведены: опознаватель находки → имя проверки.
---@type table<string, string>
local announced = {}

--- Подписка на перемены конфигурации, пока находки проводятся.
---@type any
local watcher

---@class TntNotifierSettings
---@field sinks table[]|nil Куда слать
---@field min_severity string|nil С какой серьёзности слать
---@field repeat_after number|nil Через сколько напоминать
---@field capacity integer|nil Сколько находок помнить
---@field resolve boolean|nil Слать ли отбой

--- Как настройки называются в отказах.
local TITLE = 'настройки уведомителя'

--- Какими настройки бывают.
---
--- Порог — любая строка, без сверки со словарём: опечатка в слове
--- не отсекает никого (`loud_enough`), и это решение, а не упущение.
--- Срок напоминания — больше нуля: при нуле напоминание уходило бы
--- на каждом обходе, то есть шумом, от которого уведомитель и спасает.
--- Потолок памяти — целое, а что больше нуля, проверяется следом: одной
--- записью эти два условия не сказать.
local SETTINGS = {
    sinks = { '?array_of', 'table' },
    min_severity = '?string',
    repeat_after = '?positive',
    capacity = '?integer',
    resolve = '?boolean',
}

--- Настраивает уведомления.
---
--- Негодная настройка — бросок на строке вызывающего, и прежние
--- настройки при этом остаются: всё проверяется раньше, чем меняется.
--- Приёмник без списка (`sinks = notifier.log.new()`) — тоже бросок:
--- таблицу приёмника иначе обходили бы как пустой список, и уведомления
--- молча не уходили бы никуда.
---@param opts TntNotifierSettings|nil
function Module.configure(opts)
    local check = must.at(2)

    -- Сравнением с nil, а не через `or`: так пустыми считаются и nil,
    -- и `box.NULL`, который в условии истинен.
    if opts == nil then
        opts = {}
    end

    local given = checked(opts, TITLE, SETTINGS)

    check.optional.positive(given.capacity, TITLE .. '.capacity')

    -- Список собирается заново: правка списка вызывающего после настройки
    -- добавила бы приёмник мимо проверки.
    local sinks = {}

    for index, sink in ipairs(given.sinks or {}) do
        local name = ('%s.sinks[%d]'):format(TITLE, index)

        check.callable(sink.send, name .. '.send')
        check.string(sink.name, name .. '.name')

        sinks[index] = sink
    end

    settings = {
        sinks = sinks,
        min_severity = given.min_severity or 'warning',
        repeat_after = given.repeat_after or DEFAULT_REPEAT_AFTER,
        capacity = given.capacity or DEFAULT_CAPACITY,
        resolve = given.resolve ~= false,
    }
end

--- Проверка об одной находке.
---
--- Ядро зовёт её при каждом `config:info()` и требует не уступать
--- управление, поэтому здесь только чтение памяти. Находку ищут по
--- опознавателю, а не держат в замыкании: сообщение у долгоживущей
--- находки меняется, и предупреждение должно говорить последнее.
---@param id string
---@return fun(): boolean, string|nil
local function check_of(id)
    return function()
        local entry = known[id]

        -- Забытая находка, чью проверку ещё не сняли, — уже не отказ.
        if entry == nil then
            return true
        end

        return false, ('%s: %s'):format(entry.finding.severity, tostring(entry.finding.message))
    end
end

--- Снимает все заведённые проверки.
---@param registry table
local function drop_all(registry)
    for _, name in pairs(announced) do
        registry.remove_health_check(name, { if_exists = true })
    end

    announced = {}
end

--- Сводит проверки в реестре с тем, что сейчас помнится.
local function announce()
    if not announcing then
        return
    end

    local registry = source().registry()

    for id, name in pairs(announced) do
        if known[id] == nil then
            registry.remove_health_check(name, { if_exists = true })
            announced[id] = nil
        end
    end

    for id, entry in pairs(known) do
        if announced[id] == nil and not ECHOES[entry.finding.rule] then
            local name = Module.HEALTH_CHECK_PREFIX .. id

            -- Снять перед тем, как заводить: реестр второй проверки с тем же
            -- именем не примет, а прежняя могла остаться от перезагруженного
            -- модуля — и читала бы его память, а не нашу.
            registry.remove_health_check(name, { if_exists = true })

            local ok, err = registry.add_health_check(name, check_of(id))

            if ok then
                announced[id] = name
            else
                log.warn(
                    'находка не заведена проверкой готовности',
                    { check = name, err = tostring(err) }
                )
            end
        end
    end
end

--- Заводит все проверки заново после перемены конфигурации.
---
--- Перечитывание конфигурации в 3.8.0 стирает доску предупреждений,
--- а реестр помнит, что предупреждение поднято, и второй раз его не
--- поднимает: находка есть, проверка не проходит, а предупреждения нет
--- до перемены сообщения. Проверки ролей ядро перезаводит само, наши —
--- некому. Заведённая заново проверка поднимает предупреждение с нуля.
---
--- Заводится на каждое событие `config.info`, без разбора состояния:
--- событие о начале перечитывания и событие о его конце подписчику
--- могут прийти одним последним, и узнать конец можно только по нему.
local function renew()
    drop_all(source().registry())
    announce()
end

--- Проводит находки через встроенный реестр проверок готовности.
---
--- Повторный вызов ничего не меняет. Уже известные находки заводятся
--- сразу, а не на следующем обходе.
function Module.publish_health_checks()
    announcing = true

    if watcher == nil then
        watcher = source().watch('config.info', renew)
    end

    announce()
end

--- Снимает проверки о находках и больше их не заводит.
function Module.withdraw_health_checks()
    announcing = false

    if watcher ~= nil then
        watcher:unregister()
        watcher = nil
    end

    drop_all(source().registry())
end

--- Забывает рассказанное. Нужен тестам и перезапуску с нуля.
function Module.forget()
    known = {}
    announce()
end

--- Сколько находок помнится.
---@return integer
function Module.size()
    local count = 0

    for _ in pairs(known) do
        count = count + 1
    end

    return count
end

--- Достаточно ли находка серьёзна, чтобы о ней рассказывать.
---@param finding table
---@return boolean
local function loud_enough(finding)
    local weight = WEIGHT[tostring(finding.severity)]
    local threshold = WEIGHT[settings.min_severity]

    -- Неизвестное слово в уровне не будит никого: правило, чей уровень
    -- не разобран, — это правило, о котором мы не знаем ничего, включая
    -- то, насколько оно срочное.
    --
    -- А неизвестное слово в пороге не отсекает никого: молчать обо всём
    -- из-за опечатки в настройке хуже, чем шуметь.
    --
    -- Одним выражением, а не ветками: ответ «нет» веткой был бы `false`,
    -- которого вызывающий от пустоты не отличает, — и такую ветку не
    -- проверить ничем.
    return weight ~= nil and (threshold == nil or weight >= threshold)
end

--- Отправляет событие всем приёмникам.
---
--- Приёмник, который упал, не мешает остальным: его отказ становится
--- записью в журнале, а не исключением в обходе кластера.
---@param event table
local function deliver(event)
    for _, sink in ipairs(settings.sinks) do
        local ok, err = pcall(sink.send, event)

        if not ok or err ~= nil then
            log.warn('уведомление не доставлено', {
                sink = sink.name,
                state = event.state,
                err = tostring(err),
            })
        end
    end
end

--- Собирает событие об одной находке.
---@param state string
---@param finding table
---@param at number
---@return table
local function event_of(state, finding, at)
    return {
        state = state,
        at = at,
        id = finding.id,
        severity = finding.severity,
        scope = finding.scope,
        instance = finding.instance,
        replicaset = finding.replicaset,
        rule = finding.rule,
        message = finding.message,
    }
end

--- Забывает всё, если помнить стало слишком много.
---
--- Выбирать, кого забыть, здесь не из чего: находки одного обхода
--- приходят одной секундой, и «самая старая» среди них — это просто
--- та, что попалась первой. Переполнение означает другое: кластер
--- в беде целиком, и о находках расскажут заново на следующем обходе.
--- Это шум, но не потеря.
local function make_room()
    if Module.size() <= settings.capacity then
        return
    end

    log.warn('находок больше, чем помещается в память', {
        known = Module.size(),
        capacity = settings.capacity,
    })

    known = {}
end

--- Подписчик диагностики: разбирает находки очередного обхода.
---
--- Сигнатура — та же, что у хука `on_issues`, и это не совпадение:
--- уведомитель для того и написан, чтобы вставать в неё без обёрток.
---@param issues table[] Находки обхода
function Module.on_issues(issues)
    local tools = source()
    local at = tools.now()
    local moment = tools.monotonic()
    local seen = {}

    for _, finding in ipairs(issues or {}) do
        if finding.id ~= nil and loud_enough(finding) then
            seen[finding.id] = true

            local entry = known[finding.id]

            if entry == nil then
                deliver(event_of(Module.RAISED, finding, at))

                known[finding.id] = { finding = finding, told_at = moment }
            elseif moment - entry.told_at >= settings.repeat_after then
                deliver(event_of(Module.REMINDED, finding, at))

                entry.told_at = moment
                entry.finding = finding
            else
                entry.finding = finding
            end
        end
    end

    for id, entry in pairs(known) do
        if not seen[id] then
            -- Отбой: человек, получивший ночью тревогу и не получивший
            -- отбоя, поедет в офис.
            if settings.resolve then
                deliver(event_of(Module.RESOLVED, entry.finding, at))
            end

            known[id] = nil
        end
    end

    make_room()
    announce()
end

--- Имена приёмников.
---
--- Нужны и состоянию, и журналу отказов: с двумя приёмниками иначе
--- не понять, который из них молчит.
---@return string[]
local function sink_names()
    local names = {}

    for _, sink in ipairs(settings.sinks) do
        table.insert(names, sink.name)
    end

    return names
end

--- Что с уведомлениями сейчас.
---@return table
function Module.status()
    return {
        sinks = sink_names(),
        min_severity = settings.min_severity,
        repeat_after = settings.repeat_after,
        resolve = settings.resolve,
        known = Module.size(),
    }
end

Module.configure(nil)

return Module
