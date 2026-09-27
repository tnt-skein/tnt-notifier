--- Приёмник уведомлений: файл на диске.
---
--- Строка на событие, JSON — то, что читают и человек, и агент выгрузки.
--- Смысл файла не в нём самом: его забирает тот, кто умеет слать письма
--- и вести дежурство, а узел о них знать не обязан.
---
--- Дозапись, а не переписывание: события идут вперёд, и каждое ложится
--- в конец.

local json = require('json')

local disk = require('tnt.disk')
local external = require('tnt.external')

local checked = require('tnt.notifier.settings').checked

local Module = {}

--- Как называется этот приёмник.
Module.NAME = 'file'

--- Какими настройки бывают.
---
--- Путь обязателен и не выдумывается: файл уведомлений рядом с данными
--- узла — это файл, который никто не читает.
local SETTINGS = { path = 'not_empty', name = '?string' }

--- Работа с диском: подменяется в проверках.
local source = external.install(Module, {
    append = function(path, line)
        return disk.append(path, line)
    end,
})

--- Собирает приёмник, пишущий в указанный файл.
---
--- Без пути, с незнакомым ключом или с негодным значением — бросок
--- на строке вызывающего: приёмник без пути отказывал бы на каждом
--- событии, и видно это было бы только в журнале.
---@param opts { path: string, name: string|nil }
---@return { name: string, send: fun(event: table): string|nil }
function Module.new(opts)
    local given = checked(opts, 'настройки приёмника file', SETTINGS)
    local path = given.path

    return {
        name = given.name or Module.NAME,

        send = function(event)
            local ok, err = source().append(path, json.encode(event) .. '\n')

            if not ok then
                return tostring(err)
            end

            return nil
        end,
    }
end

return Module
