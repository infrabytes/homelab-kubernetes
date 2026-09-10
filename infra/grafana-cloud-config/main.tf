# Grafana Cloud stack resources (dashboards, folders, alerting, settings).
#
# Managed here: the alerting folder + rule groups. Adopt the hand-configured
# UI state (dashboards, contact points, notification policy, org
# preferences) via the import workflow in README.md.

# Grafana Cloud auto-provisions the managed Prometheus/Loki datasources on
# every stack; they cannot be managed with Terraform, only referenced. The
# name pattern is always `grafanacloud-<stack-slug>-<type>`, with the slug
# taken from the stack URL.
locals {
  stack_slug = regex("^https://([a-z0-9-]+)\\.grafana\\.net/?$", var.grafana_cloud_stack_url)[0]
}

data "grafana_data_source" "prom" {
  name = "grafanacloud-${local.stack_slug}-prom"
}

data "grafana_data_source" "logs" {
  name = "grafanacloud-${local.stack_slug}-logs"
}

# Alerting rule groups must live in a folder. Dashboards can be adopted into
# this folder later (see the adopt-workflow in README.md).
resource "grafana_folder" "talos" {
  title = "Talos"
  uid   = "talos"
}

# Cilium Flows - Hubble Observer (grafana.com #23862), managed here instead of
# the chart's grafanaDashboard (that needs the grafana-operator CRD, which this
# cluster does not run). The JSON in dashboards/ is pre-resolved for the
# release namespace and CF2CNP URL; the single ${DS_LOKI} placeholder is filled
# with the managed Loki datasource uid at apply time.
resource "grafana_folder" "cilium" {
  title = "Cilium"
  uid   = "cilium"
}

resource "grafana_dashboard" "cilium_hubble_flows" {
  folder = grafana_folder.cilium.id
  config_json = replace(
    file("${path.module}/dashboards/cilium-hubble-flows.json"),
    "$${DS_LOKI}",
    data.grafana_data_source.logs.uid,
  )
}

# Import: terragrunt import 'grafana_rule_group.<name>' "<folderUID>:<groupName>"

resource "grafana_rule_group" "critical" {
  name             = "critical"
  folder_uid       = grafana_folder.talos.uid
  interval_seconds = 60

  rule {
    name           = "Node is down"
    for            = "5m"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary = "Node {{ $labels.instance }} is down or unreachable"
    }
    labels = {
      severity = "critical"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.prom.uid
      query_type     = "prometheus"
      relative_time_range {
        from = 660
        to   = 60
      }
      model = jsonencode({
        datasource = {
          type = "prometheus"
          uid  = data.grafana_data_source.prom.uid
        }
        expr          = "up{job=~\"integrations/kubernetes/kubelet\"} == bool 0"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
        range         = false
        refId         = "query"
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
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }

  rule {
    name           = "Metrics pipeline silent"
    for            = "10m"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary = "Metrics pipeline stopped reporting to Grafana Cloud (Alloy collectors silent)"
    }
    labels = {
      severity = "critical"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.prom.uid
      query_type     = "prometheus"
      relative_time_range {
        from = 660
        to   = 60
      }
      model = jsonencode({
        datasource = {
          type = "prometheus"
          uid  = data.grafana_data_source.prom.uid
        }
        expr          = "absent(grafana_kubernetes_monitoring_collector_info)"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
        range         = false
        refId         = "query"
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
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }

  rule {
    name           = "Longhorn manager down"
    for            = "5m"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary = "Longhorn manager {{ $labels.instance }} is down"
    }
    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.prom.uid
      query_type     = "prometheus"
      relative_time_range {
        from = 660
        to   = 60
      }
      model = jsonencode({
        datasource = {
          type = "prometheus"
          uid  = data.grafana_data_source.prom.uid
        }
        expr          = "up{job=\"longhorn-backend\"} == bool 0"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
        range         = false
        refId         = "query"
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
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }
}

# Capacity / lifecycle: full-cardinality and slow-moving checks.
resource "grafana_rule_group" "capacity" {
  name             = "capacity"
  folder_uid       = grafana_folder.talos.uid
  interval_seconds = 300

  rule {
    name           = "Active series budget high"
    for            = "15m"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary = "Active series count exceeds 9000, approaching the 10K free-tier limit"
    }
    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.prom.uid
      query_type     = "prometheus"
      relative_time_range {
        from = 660
        to   = 60
      }
      model = jsonencode({
        datasource = {
          type = "prometheus"
          uid  = data.grafana_data_source.prom.uid
        }
        expr          = "count({__name__=~\".+\"}) > bool 9000"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
        range         = false
        refId         = "query"
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
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }

  rule {
    name           = "Certificate expiring soon"
    for            = "10m"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary = "Certificate {{ $labels.name }} ({{ $labels.namespace }}) expires in less than 14 days"
    }
    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.prom.uid
      query_type     = "prometheus"
      relative_time_range {
        from = 660
        to   = 60
      }
      model = jsonencode({
        datasource = {
          type = "prometheus"
          uid  = data.grafana_data_source.prom.uid
        }
        expr          = "certmanager_certificate_expiration_timestamp_seconds - time() < bool 86400 * 14"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
        range         = false
        refId         = "query"
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
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }
}

# Resource guards: the sizing re-audit's alert pair. The last-terminated gauge
# latches until the next clean exit, so the restart increase pins the OOMKill
# rule to a recent kill; the saturation rule compares the 5m working-set peak
# against each container's own memory limit.
resource "grafana_rule_group" "resources" {
  name             = "resources"
  folder_uid       = grafana_folder.talos.uid
  interval_seconds = 60

  rule {
    name           = "Container OOMKilled"
    for            = "5m"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary = "Container {{ $labels.container }} in {{ $labels.namespace }}/{{ $labels.pod }} was OOMKilled and restarted"
    }
    labels = {
      severity = "critical"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.prom.uid
      query_type     = "prometheus"
      relative_time_range {
        from = 660
        to   = 60
      }
      model = jsonencode({
        datasource = {
          type = "prometheus"
          uid  = data.grafana_data_source.prom.uid
        }
        expr          = "(kube_pod_container_status_last_terminated_reason{reason=\"OOMKilled\"} == 1) and on (namespace, pod, container) (increase(kube_pod_container_status_restarts_total[1h]) > 0)"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
        range         = false
        refId         = "query"
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
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }

  rule {
    name           = "Container memory above 90% of limit"
    for            = "15m"
    condition      = "threshold"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary = "Container {{ $labels.container }} in {{ $labels.namespace }}/{{ $labels.pod }} runs above 90% of its memory limit"
    }
    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "query"
      datasource_uid = data.grafana_data_source.prom.uid
      query_type     = "prometheus"
      relative_time_range {
        from = 660
        to   = 60
      }
      model = jsonencode({
        datasource = {
          type = "prometheus"
          uid  = data.grafana_data_source.prom.uid
        }
        expr          = "(max_over_time(max by (namespace, pod, container) (container_memory_working_set_bytes)[5m:1m]) / on (namespace, pod, container) max by (namespace, pod, container) (kube_pod_container_resource_limits{resource=\"memory\"})) > bool 0.9"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
        range         = false
        refId         = "query"
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
        expression    = "query"
        intervalMs    = 1000
        maxDataPoints = 43200
        refId         = "threshold"
        type          = "threshold"
      })
    }
  }
}
