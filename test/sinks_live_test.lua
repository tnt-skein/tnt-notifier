--- Отправка уведомления на настоящую службу.
---
--- Двойник клиента показывает, что приёмник собирает запрос правильно,
--- но не то, что запрос уходит: клиент, собранный без соединений или
--- с негодными настройками, в проверке с двойником выглядит исправным.

local t = require('luatest')
local json = require('json')

local g = t.group('tnt.notifier.sinks_live')

local helper = dofile('test/helper.lua')
local testing = helper.testing

--- Приёмник вместе с клиентом HTTP, которого он берёт.
---
--- Клиент — тот, что назвал помощник, а не первый попавшийся: сверка
--- текста отказа ниже шла бы иначе против вчерашнего клиента, у которого
--- отказ — строка, и проходила бы при любой поломке сегодняшнего.
local Module = helper.HTTP_SINK

---@type any
local http_sink

--- Служба, принимающая уведомления.
---@type any
local service

--- Что она приняла.
---@type table[]
local taken

--- Порт службы: занятый порт — обычное дело на общей машине, поэтому
--- берётся первый свободный из небольшого набора.
---@type integer
local port

g.before_each(function()
    taken = {}
    http_sink = testing.load_sources(Module, 'tnt.notifier.sink.http')

    local server = require('http.server')

    for candidate = 18800, 18820 do
        local attempt = server.new('127.0.0.1', candidate, { log_requests = false })
        local started = pcall(attempt.start, attempt)

        if started then
            service = attempt
            port = candidate

            break
        end
    end

    assert(service ~= nil, 'свободного порта для службы не нашлось')

    service:route({ path = '/hook', method = 'POST' }, function(request)
        table.insert(taken, { body = request:read_cached(), token = request.headers['authorization'] })

        return { status = 202 }
    end)

    service:route({ path = '/отказ', method = 'POST' }, function()
        return { status = 503 }
    end)

    service:route({ path = '/переезд', method = 'POST' }, function()
        return { status = 302, headers = { location = '/hook' } }
    end)
end)

g.after_each(function()
    service:stop()
    testing.unload_sources(Module)
end)

g.test_event_reaches_the_service = function()
    local sink = http_sink.new({
        url = ('http://127.0.0.1:%d/hook'):format(port),
        headers = { ['authorization'] = 'Bearer слово' },
    })

    local refusal = sink.send({ state = 'raised', id = 'находка', message = 'реплика отстала' })

    t.assert_equals(refusal, nil)
    t.assert_equals(#taken, 1)

    local first = assert(taken[1], 'служба ничего не приняла')

    t.assert_equals(json.decode(first.body).message, 'реплика отстала')
    t.assert_equals(first.token, 'Bearer слово')
end

g.test_refusing_service_is_reported = function()
    local sink = http_sink.new({ url = ('http://127.0.0.1:%d/отказ'):format(port) })

    t.assert_str_contains(sink.send({ state = 'raised' }), '503')
end

g.test_moved_service_is_reported_and_not_followed = function()
    -- На 302 клиент пошёл бы по `Location` методом GET и без тела: служба
    -- ответила бы 200 на пустой запрос, и событие числилось бы
    -- доставленным, не дойдя.
    local sink = http_sink.new({ url = ('http://127.0.0.1:%d/переезд'):format(port) })

    t.assert_equals(
        sink.send({ state = 'raised', message = 'реплика отстала' }),
        'служба ответила 302'
    )
    t.assert_equals(taken, {}, 'по новому адресу не ходили')
end

g.test_silent_address_is_reported = function()
    -- Служба не отвечает вовсе: приёмник обязан вернуть отказ, а не
    -- уронить обход кластера.
    local sink = http_sink.new({ url = 'http://127.0.0.1:1/hook', timeout = 0.5 })
    local ok, refusal = pcall(sink.send, { state = 'raised' })

    t.assert_equals(ok, true, 'падать приёмник не вправе')
    -- Сверка ниже чего-то стоит только против клиента, что назвал
    -- помощник: см. `Module`.
    local origin = assert(debug.getinfo(require('tnt.http').new))

    t.assert_str_contains(origin.source, helper.HTTP_CLIENT)
    -- Отказ `tnt.http` стал таблицей, а приёмник склеивает его со своими
    -- словами через `tostring`: причина обязана дойти прежним текстом,
    -- а не адресом таблицы.
    t.assert_type(refusal, 'string')
    t.assert_str_contains(
        refusal,
        'служба не ответила: POST http://127.0.0.1:1/hook: сервер не ответил'
    )
end
