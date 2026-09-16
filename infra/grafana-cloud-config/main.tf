# Grafana Cloud watchdog (out-of-cluster dead man).
#
# After the cutover the cluster's metrics and logs live in the local stack
# (platform/observability); this unit keeps only what must survive the cluster
# dying with them: the PVE-maintenance rules (fed by the Ansible playbook) and
# the cluster-heartbeat rule (fed by platform/observability/heartbeat-cronjob.yaml
# pushing into Cloud Loki). Both notify through the hand-configured `GrafanaBot`
# Discord contact point and the notification policy rooted at it — they are not
# managed here; see README ("Adopting existing resources") to import them.
#
# This unit is order-independent: the provider talks to the Grafana Cloud API,
# not the cluster. Adopt hand-configured UI state (org preferences) via the
# import workflow in README.md.

locals {
  stack_slug = regex("^https://([a-z0-9-]+)\\.grafana\\.net/?$", var.grafana_cloud_stack_url)[0]
}

# Grafana Cloud auto-provisions the managed Loki datasource on every stack; it
# cannot be managed with Terraform, only referenced. The name pattern is always
# `grafanacloud-<stack-slug>-logs`, with the slug taken from the stack URL.
data "grafana_data_source" "loki" {
  name = "grafanacloud-${local.stack_slug}-logs"
}

# Alerting rule groups must live in a folder; dashboards are adopted into it.
resource "grafana_folder" "talos" {
  title = "Talos"
  uid   = "talos"
}

# Rolling PVE host maintenance: per-host run results pushed by
# ansible/proxmox-node-updates.yml to the managed Loki (job=proxmox-node-updates).
# The single $${DS_LOKI} placeholder is filled with the managed Loki datasource
# uid at apply time.
resource "grafana_dashboard" "proxmox_maintenance" {
  folder = grafana_folder.talos.id
  config_json = replace(
    file("${path.module}/dashboards/proxmox-maintenance.json"),
    "$${DS_LOKI}",
    data.grafana_data_source.loki.uid,
  )
}

# Dead-man switch for the cluster itself: the heartbeat CronJob pushes
# {job="cluster-heartbeat"} every 5 minutes from inside the cluster, so 15
# minutes of silence means the cluster (or its CronJob) is gone. Nothing local
# can alert on that — the local Grafana goes down with the cluster.
resource "grafana_rule_group" "watchdog" {
  name             = "watchdog"
  folder_uid       = grafana_folder.talos.uid
  interval_seconds = 60

  rule {
    name           = "Cluster heartbeat missing"
    for            = "0s"
    condition      = "threshold"
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    annotations = {
      summary = "No cluster heartbeat in 15 minutes — the cluster is down or its heartbeat CronJob stopped pushing"
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
        expr          = "sum(count_over_time({job=\"cluster-heartbeat\"} |= \"alive\" [15m]))"
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
        reducer       = "last"
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
