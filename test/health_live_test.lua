--- Находки во встроенном реестре на живом инстансе с конфигурацией.
---
--- Двойник реестра показывает, что и когда заводится, но не главное:
--- что отказ проверки становится предупреждением конфигурации и что оно
--- переживает перечитывание. Второе в 3.8.0 не бесплатно — ядро стирает
--- доску и не поднимает предупреждение заново, — и показать это может
--- только настоящее ядро.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.notifier.health.live')

g.before_all(function()
    g.server = helper.start_configured('notifier-001-a')
end)

g.after_all(function()
    helper.stop_node(g.server)
end)

g.test_finding_alert_survives_configuration_reload = function()
    local seen = g.server:exec(function()
        -- Перечитывания в аннотациях модуля нет, хотя метод публичный.
        ---@type any
        local config = require('config')
        local notifier = require('tnt.notifier')

        --- Предупреждения конфигурации о находках.
        local function alerts()
            local found = {}

            for _, alert in ipairs(config:info().alerts) do
                if alert.message:find('cluster.findings', 1, true) then
                    table.insert(found, alert.message)
                end
            end

            return found
        end

        notifier.on_issues({
            {
                id = 'disk:instance:storage-001-b',
                rule = 'disk',
                severity = 'critical',
                message = 'каталог данных исчез',
            },
        })
        notifier.publish_health_checks()

        local before = alerts()

        config:reload()

        -- Подписчик на перемены конфигурации зовётся в своём файбере.
        local after

        require('luatest').helpers.retrying({ timeout = 5 }, function()
            after = alerts()
            assert(#after == 1)
        end)

        notifier.on_issues({})

        return { before = before, after = after, resolved = alerts() }
    end)

    local expected = {
        'Readiness health check "cluster.findings.disk:instance:storage-001-b" failed: critical: каталог данных исчез',
    }

    t.assert_equals(seen.before, expected)
    t.assert_equals(seen.after, expected)
    t.assert_equals(seen.resolved, {}, 'ушедшая находка снимает предупреждение')
end
