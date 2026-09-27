--- Приёмник уведомлений: журнал самого узла.
---
--- Приёмник по умолчанию и единственный, который работает всегда: сети
--- может не быть, каталога может не быть, а журнал у узла есть с первой
--- секунды. Толку от него меньше, чем от письма, — но «никуда не слать»
--- хуже, чем «слать туда, где хотя бы останется след».

local log = require('tnt.log').new('tnt.notifier')

local Module = {}

--- Как называется этот приёмник.
Module.NAME = 'log'

--- Каким уровнем писать событие.
---
--- Тревога пишется предупреждением, а не ошибкой: ошибка в журнале узла
--- означает, что сломался сам узел, а здесь сломалось что-то в кластере,
--- и узел об этом рассказывает.
local LEVELS = {
    critical = 'warn',
    warning = 'warn',
}

--- Собирает приёмник.
---@return { name: string, send: fun(event: table) }
function Module.new()
    return {
        name = Module.NAME,

        send = function(event)
            local level = LEVELS[tostring(event.severity)] or 'info'

            log[level]('находка ' .. tostring(event.state), {
                id = event.id,
                severity = event.severity,
                instance = event.instance,
                message = event.message,
            })
        end,
    }
end

return Module
