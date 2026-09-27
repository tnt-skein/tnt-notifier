--- Приёмник уведомлений: письмо человеку.
---
--- Тот случай, ради которого уведомитель и писался: ночью в панель
--- не смотрит никто, а письмо будит телефон. Остальные приёмники —
--- журнал и файл — оставляют след, письмо доходит.
---
--- Тема письма собирается так, чтобы её хватало вместо самого письма:
--- по уведомлению на экране блокировки человек должен понять, что
--- случилось и насколько срочно, не открывая почту.
---
--- Отбой шлётся тем же письмом, что и тревога, но с другим словом
--- в теме. Отдельная настройка «слать ли отбой» живёт в уведомителе:
--- приёмник шлёт то, что дали.

local mail = require('tnt.mail')

local checked = require('tnt.notifier.settings').checked

local Module = {}

--- Как называется этот приёмник.
Module.NAME = 'mail'

--- Какими настройки бывают.
---
--- Адрес — как его понимает почта: строка, таблица `{ address, name }`
--- или их список. Получатель обязателен, отправитель — нет: без него
--- письмо уходит от отправителя почты по умолчанию.
local SETTINGS = { to = 'string|table', from = '?string|table', name = '?string' }

--- Слово в теме по состоянию находки.
---
--- По-русски и в начале темы: почтовые программы обрезают тему справа,
--- и главное слово обязано уцелеть.
local WORDS = {
    raised = 'ТРЕВОГА',
    reminded = 'всё ещё',
    resolved = 'отбой',
}

--- Собирает тему письма.
---@param event table
---@return string
local function subject_of(event)
    local word = WORDS[tostring(event.state)] or tostring(event.state)
    local about = event.instance or event.replicaset or 'кластер'

    return ('[%s] %s: %s'):format(word, about, tostring(event.message))
end

--- Собирает тело письма.
---
--- Всё, что известно о находке, в столбик: человек читает это с телефона
--- и не может спросить уточнений.
---@param event table
---@return string
local function text_of(event)
    local lines = {
        ('Находка: %s'):format(tostring(event.message)),
        ('Состояние: %s'):format(tostring(event.state)),
        ('Серьёзность: %s'):format(tostring(event.severity)),
        ('Правило: %s'):format(tostring(event.rule)),
    }

    if event.instance ~= nil then
        table.insert(lines, ('Узел: %s'):format(event.instance))
    end

    if event.replicaset ~= nil then
        table.insert(lines, ('Репликасет: %s'):format(event.replicaset))
    end

    table.insert(lines, ('Опознаватель: %s'):format(tostring(event.id)))

    return table.concat(lines, '\r\n')
end

--- Собирает приёмник, шлющий письма.
---
--- Получатели задаются здесь, а не в почте: у дежурного свой адрес,
--- и он не тот, на который узел шлёт отчёты. Без получателя,
--- с незнакомым ключом или с негодным значением — бросок на строке
--- вызывающего.
---@param opts { to: any, from: any|nil, name: string|nil }
---@return { name: string, send: fun(event: table): string|nil }
function Module.new(opts)
    local given = checked(opts, 'настройки приёмника mail', SETTINGS)

    return {
        name = given.name or Module.NAME,

        send = function(event)
            local sent, err = mail.send({
                to = given.to,
                from = given.from,
                subject = subject_of(event),
                text = text_of(event),
            })

            if not sent then
                return tostring(err)
            end

            return nil
        end,
    }
end

return Module
