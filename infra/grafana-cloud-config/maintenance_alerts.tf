# Maintenance-run alert rules (proxmox-node-updates).
#
# The Ansible playbook pushes one JSON line per host plus a run summary to the
# managed Loki (`job="proxmox-node-updates"`); these rules alert on a failed
# roll and on the job going silent. Managed Loki rules read from the same
# datasource the kubelet/Longhorn rules use, only with `query_type: loki` and
# range expressions instead of instant PromQL.

data "grafana_data_source" "loki" {
  name = "grafanacloud-${local.stack_slug}-logs"
}

resource "grafana_rule_group" "proxmox_maintenance" {
  name             = "proxmox-maintenance"
  folder_uid       = grafana_folder.talos.uid
  interval_seconds = 300

  rule {
    name           = "Proxmox maintenance run failed"
    for            = "0s"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary = "A Proxmox host-maintenance run failed or aborted — check the Loki line for the failing host and step"
    }
    labels = {
      severity = "critical"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.loki.uid
      query_type     = "range"
      relative_time_range {
        from = 900
        to   = 0
      }
      model = jsonencode({
        datasource = {
          type = "loki"
          uid  = data.grafana_data_source.loki.uid
        }
        expr          = "sum by (host) (count_over_time({job=\"proxmox-node-updates\"} |= \"result=failed\" [15m]))"
        queryType     = "range"
        refId         = "query"
      })
    }
    data {
      ref_id         = "reduce"
      datasource_uid = "__expr__"
      query_type     = ""
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        conditions = []
        datasource = {
          type = "__expr__"
          uid  = "__expr__"
        }
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        reducer       = "max"
        refId         = "reduce"
        type          = "reduce"
      })
    }
    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      query_type     = "threshold"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        conditions = [{
          evaluator = {
            params = [0]
            type   = "gt"
          }
        }]
        datasource = {
          type = "__expr__"
          uid  = "__expr__"
        }
        expression    = "reduce"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }

  rule {
    name           = "Proxmox maintenance dead man"
    for            = "1d"
    condition      = "threshold"
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    annotations = {
      summary = "No successful Proxmox host-maintenance run in 8 days — the windrunner timer or the playbook is broken"
    }
    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.loki.uid
      query_type     = "range"
      relative_time_range {
        from = 691200
        to   = 0
      }
      model = jsonencode({
        datasource = {
          type = "loki"
          uid  = data.grafana_data_source.loki.uid
        }
        expr          = "sum(count_over_time({job=\"proxmox-node-updates\"} |= \"result=success\" [8d]))"
        queryType     = "range"
        refId         = "query"
      })
    }
    data {
      ref_id         = "reduce"
      datasource_uid = "__expr__"
      query_type     = ""
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        conditions = []
        datasource = {
          type = "__expr__"
          uid  = "__expr__"
        }
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        reducer       = "lastNotNull"
        refId         = "reduce"
        type          = "reduce"
      })
    }
    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      query_type     = "threshold"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        conditions = [{
          evaluator = {
            params = [1]
            type   = "lt"
          }
        }]
        datasource = {
          type = "__expr__"
          uid  = "__expr__"
        }
        expression    = "reduce"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }
}
