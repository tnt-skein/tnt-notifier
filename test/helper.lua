--- Общие средства проверок уведомителя: исходники, оснастка, двойник
--- диска, письмо по номеру и узел по конфигурации.
---
--- Исходники пакета читаются с диска, а не через `require`: у Tarantool
--- свой загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.clock`, `tnt.disk`, `tnt.http`, `tnt.log`, `tnt.mail`,
--- `tnt.must`, `tnt.external` — берутся из `.rocks` обычным `require`:
--- проверяется этот пакет, а не они. На временном узле они берутся так же.
---
--- Рок `http` нужен только проверкам: живая проверка приёмника HTTP шлёт
--- событие его серверу. Он стоит в `.rocks` (`make deps`).
---
--- Оснастка в `test/testing/` — загрузчик исходников, ловушка журнала,
--- запись файлов и временный узел — грузится так же, файлами, и один раз
--- на процесс: второй экземпляр загрузчика не знал бы, что вытеснил
--- первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: узел берёт файлы и загрузчик,
--- ловушка журнала — загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

local sources = package.loaded['tnt.testing.sources']
local node = package.loaded['tnt.testing.node']

local helper = {}

--- Оснастка проверок под теми именами, что зовут проверки: загрузка
--- и выгрузка исходников, уже загруженный модуль и ловушка журнала.
helper.testing = {
    load_sources = sources.load,
    unload_sources = sources.unload,
    module = sources.module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

--- Модули пакета по именам: путь складывается из имени.
---@param names string[]
---@return { name: string, path: string }[]
local function own(names)
    local list = {}

    for _, name in ipairs(names) do
        table.insert(list, { name = name, path = (name:gsub('%.', '/')) .. '.lua' })
    end

    return list
end

--- Приёмники и уведомитель в порядке зависимостей. Почта и слой диска,
--- которые приёмники берут при загрузке, приходят из `.rocks`. Проверка
--- настроек — раньше всех модулей пакета: её берут и приёмники, и сам
--- уведомитель.
helper.MODULES = own({
    'tnt.notifier.settings',
    'tnt.notifier.sink.log',
    'tnt.notifier.sink.file',
    'tnt.notifier.sink.http',
    'tnt.notifier.sink.mail',
    'tnt.notifier',
})

--- Приёмник журнала отдельно: проверка уровня записи грузит его одного
--- поверх подменённого журнала.
helper.LOG_SINK = own({ 'tnt.notifier.sink.log' })

--- Приёмник HTTP вместе с проверкой настроек; клиент он берёт из `.rocks`.
helper.HTTP_SINK = own({ 'tnt.notifier.settings', 'tnt.notifier.sink.http' })

--- Откуда обязан прийти клиент HTTP, которого берёт приёмник: сверка
--- текста его отказа чего-то стоит только против поставленного `tnt-http`.
helper.HTTP_CLIENT = '.rocks/share/tarantool/tnt/http.lua'

--- Ставит двойник диска на слой из `.rocks`: дозапись идёт в память.
---
--- Приёмник файла зовёт у диска одну дозапись, и двойнику больше знать
--- нечего. Отказ задаётся проверкой полем `append_error`.
---@return table fake Что лежит в файлах (`contents`) и чем отказывать дозаписи (`append_error`)
function helper.use_disk()
    local fake = { contents = {} }

    require('tnt.disk')._set_source({
        append = function(path, content)
            if fake.append_error ~= nil then
                return false, fake.append_error
            end

            fake.contents[path] = (fake.contents[path] or '') .. content

            return true
        end,
    })

    return fake
end

--- Возвращает слою диска настоящую дозапись: он из `.rocks` и живёт
--- дольше одной проверки.
function helper.release_disk()
    require('tnt.disk')._set_source(nil)
end

--- Письмо под указанным номером; его отсутствие — ошибка самой проверки.
---@param letters any
---@param index integer
---@return any
function helper.at(letters, index)
    return (assert((letters or {})[index], ('письма №%d нет'):format(index)))
end

--- Файл вызывающего.
---
--- Имя выдумано и в пакете не встречается нигде: совпади оно с чем-то
--- настоящим, бросок с местом внутри пакета мог бы сойти за правильный.
local CALLER_FILE = '/узел/уведомления.lua'

--- Место, которое обязан назвать бросок: строка вызывающего.
helper.CALLER = CALLER_FILE .. ':1: '

--- Чужой код: настраивает уведомитель или собирает приёмник.
---
--- Ответ берётся в переменную, а не отдаётся хвостом: хвостовой вызов
--- снял бы кадр чужого кода со стека, и бросок назвал бы кадр выше —
--- туда, где кода вызывающего уже нет.
local setup_by_caller =
    assert(loadstring('return function(setup, opts) local made = setup(opts) return made end', '@' .. CALLER_FILE))()

--- Бросок настройки, сделанной чужим кодом: место и текст целиком.
---
--- Ловится `pcall`, а не проверкой luatest на подстроку: место в броске —
--- то самое, что проверяется, и сверять его надо дословно.
---@param setup fun(opts: any): any `configure` уведомителя либо `new` приёмника
---@param opts any Настройки
---@return string
function helper.refusal(setup, opts)
    local made, raised = pcall(setup_by_caller, setup, opts)

    t.assert_equals(made, false, 'негодная настройка прошла без броска')

    return tostring(raised)
end

--- Поднимает одиночный узел по декларативной конфигурации.
---
--- Роли у пакета нет, поэтому исходники узел получает после подъёма —
--- в `package.loaded`, абсолютными путями: путь поиска модулей узла
--- смотрит только в `.rocks`, откуда он берёт и зависимости. Проверка
--- обязана остановить узел сама — `stop_node`.
---@param name string Имя инстанса
---@return table server
function helper.start_configured(name)
    local server = node.configured(name, {}, {})

    server:exec(function(modules)
        for _, module in ipairs(modules) do
            package.loaded[module.name] = assert(loadfile(module.path))()
        end
    end, { sources.absolute(helper.MODULES) })

    return server
end

--- Останавливает узел и убирает его каталог.
helper.stop_node = node.stop

return helper
