module VCAP::CloudController
  module Presenters
    module V3
      module AppManifestPresenters
        class ProcessPropertiesPresenter
          def to_hash(app:, **_)
            processes = app.processes.sort_by(&:type).map { |process| process_hash(process) }
            { processes: processes.presence }
          end

          def process_hash(process)
            {
              'type' => process.type,
              'instances' => process.instances,
              'memory' => add_units(process.memory),
              'disk_quota' => add_units(process.disk_quota),
              'log_quota' => add_units_log_quota(process.log_quota),
              'command' => process.command,
              'health-check-type' => process.health_check_type,
              'health-check-http-endpoint' => process.health_check_http_endpoint,
              'timeout' => process.health_check_timeout,
            }.compact
          end

          def add_units(val)
            "#{val}M"
          end

          def add_units_log_quota(val)
            return 'unlimited' if val == -1

            units = ['Bs', 'KBs', 'MBs', 'GBs']
            i = 0
            while val % 1024 == 0 && i < units.length - 1
              val /= 1024
              i += 1
            end

            "#{val}#{units[i]}"
          end
        end
      end
    end
  end
end
