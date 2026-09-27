--- Приёмник уведомлений: чужая служба по HTTP.
---
--- Тот самый крючок, в который вешают дежурство: Alertmanager, чат,
--- собственный сборщик. Тело — то же событие в JSON, что и в файле:
--- один вид события на все приёмники, иначе они разъедутся.
---
--- Срок ответа короткий намеренно. Отправка идёт в том же файбере, что
--- и обход кластера, и служба, отвечающая минуту, остановила бы
--- диагностику на эту минуту — то есть сломала бы то, о чём пришла
--- рассказать.
---
--- Повторов нет, и это решение приёмника, а не клиента. О находке, которая
--- никуда не делась, напомнит срок напоминания, об ушедшей скажет отбой,
--- а очередь неотправленного пришлось бы где-то держать — и она пережила
--- бы перезапуск не лучше самой находки. Поэтому клиент берётся с явно
--- выключенными повторами: его умолчание разумно для запросов к чужому
--- API, но не для уведомления.
---
--- Переходов по `Location` нет тоже. На 301 и 302 клиент по правилам HTTP
--- пошёл бы дальше методом GET и без тела: служба по новому адресу
--- ответила бы 200, и событие, которого она не получила, числилось бы
--- доставленным. Переход — отказ со своим кодом в журнале, и адрес службы
--- правится в настройке.

local external = require('tnt.external')
local must = require('tnt.must')

local checked = require('tnt.notifier.settings').checked

local Module = {}

--- Как называется этот приёмник.
Module.NAME = 'http'

--- Сколько ждать ответа службы.
local DEFAULT_TIMEOUT = 2

--- Как настройки называются в отказах.
local TITLE = 'настройки приёмника http'

--- Какими настройки бывают.
---
--- Адрес обязателен: приёмник без него отказывал бы на каждом событии,
--- и видно это было бы только в журнале.
local SETTINGS = { url = 'not_empty', timeout = '?positive', headers = '?table', name = '?string' }

--- Заголовок типа тела.
local CONTENT_TYPE = 'content-type'

--- Настоящий клиент HTTP.
---
--- Отдельной функцией, а не телом во внешней зависимости: подменённая внешняя зависимость скрывает
--- её целиком, и проверить, что умолчание собирает настоящий клиент,
--- иначе нечем — а приёмник с подменой вместо умолчания не отправит
--- в кластере ничего.
---@param timeout number Сколько ждать ответа
---@return table
function Module._default_client(timeout)
    local client, err = require('tnt.http').new({ timeout = timeout, retry = { attempts = 1 }, max_redirects = 0 })

    -- Через assert: срок проверен при сборке приёмника, остальные
    -- настройки наши. Отказать клиент может разве что сроку короче
    -- миллисекунды или бесконечному — проверка приёмника пропускает их
    -- как числа больше нуля, — либо если однажды ужесточит свои проверки.
    -- Молчаливый `nil` тогда означал бы «уведомления не уходят» — без
    -- единой записи о том, почему.
    return (assert(client, err))
end

--- Клиент HTTP: подменяется в проверках.
local source = external.install(Module, { client = Module._default_client })

--- Заголовки приёмника: копия, а не таблица вызывающего.
---
--- Дописать умолчание в таблицу вызывающего значило бы поменять её
--- у него на руках: та же таблица, отданная потом его собственному
--- запросу, понесла бы туда наш тип тела.
---
--- Имена приводятся к нижнему регистру: `Content-Type` вызывающего и наш
--- `content-type` иначе ехали бы в клиент вдвоём, и какой из них уйдёт
--- на сервер, решал бы порядок `pairs`. Значение — строка или число:
--- число клиент приводит сам, а прочее он отвергает уже при отправке,
--- на каждом событии.
---
--- Бросок называет строку того, кто собирал приёмник: эту функцию зовёт
--- `new`, и не хвостом.
---@param given table|nil Заголовки вызывающего
---@return table<string, string|number>
local function headers_of(given)
    local check = must.at(3)
    local headers = {}

    for name, value in pairs(given or {}) do
        check.string(name, ('имя заголовка в «%s.headers»'):format(TITLE))
        check.kind(value, ('%s.headers.%s'):format(TITLE, name), 'string|number')

        headers[name:lower()] = value
    end

    headers[CONTENT_TYPE] = headers[CONTENT_TYPE] or 'application/json'

    return headers
end

--- Собирает приёмник, шлющий события на указанный адрес.
---
--- Без адреса, с незнакомым ключом или с негодным значением — бросок
--- на строке вызывающего.
---@param opts { url: string, name: string|nil, timeout: number|nil, headers: table|nil }
---@return { name: string, send: fun(event: table): string|nil }
function Module.new(opts)
    local given = checked(opts, TITLE, SETTINGS)
    local url = given.url
    local timeout = given.timeout or DEFAULT_TIMEOUT
    local headers = headers_of(given.headers)

    return {
        name = given.name or Module.NAME,

        send = function(event)
            -- Событие едет полем `json`: клиент сам его закодирует
            -- и сам поставит заголовок типа, а заданный вызывающим
            -- останется главнее.
            local response, err =
                source().client(timeout):post(url, { json = event, headers = headers, timeout = timeout })

            if response == nil then
                return ('служба не ответила: %s'):format(tostring(err))
            end

            -- Удачей считается любой ответ из разряда 2xx: службы отвечают
            -- и 200, и 202, и 204, а различать их незачем — важно, что
            -- событие принято.
            if not response:ok() then
                return ('служба ответила %s'):format(tostring(response.status))
            end

            return nil
        end,
    }
end

return Module
