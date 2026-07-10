#!/usr/bin/env python3
"""Patch Grafana dashboard datasource references.

Recursively walks all JSON objects in a dashboard file and patches
datasource references so provisioned dashboards bind to the datasource
configured for the target org.

Supported rewrites:
- Legacy panel objects with ``{"type": "prometheus", "uid": "..."}``
- Any ``uid`` field using a Grafana datasource variable (for example
    ``${DS_PROMETHEUS}``, ``${ds_prometheus}``)
- Datasource refs using datasource names are normalized to the target UID
    (for example ``uid: Infrastructure`` -> ``uid: mimir-infra``)
- V2 resources with ``{"datasource": {"name": "${DS_PROMETHEUS}"}}``
    are normalized to UID-based refs
- Datasource variable defaults for ``DS_PROMETHEUS`` (``current.text`` = name,
  ``current.value`` = uid)
- Query variables are bound to the target Prometheus datasource UID when
    their datasource is missing/placeholder.
- Optional PromQL dedupe rewrite for app dashboards: wraps all ``horde_*``
    metric selectors with ``max without(...)`` to collapse legacy label drift
    (for example ``environment``/``instance`` mismatches across migrations).

Usage:
        patch_dashboard_uid.py <dashboard.json> <target-uid> [target-datasource-name] [collapse-labels-csv] [preserve-uids-csv]

``preserve-uids-csv`` lists datasource UIDs that must NOT be rewritten to the
target UID (for example cross-tenant ``mimir-app``/``mimir-telemetry`` refs in
a multi-datasource dashboard patched against a single-tenant target).

The file is modified in-place.
"""
import json
import re
import sys
from pathlib import Path

_GRAFANA_VAR_RE = re.compile(r'^\$\{[^}]+\}$')
_DS_VAR_RE = re.compile(r'^\$\{(?:DS_|ds_)[^}]*\}$')
_HORDE_METRIC_RE = re.compile(r'\b(horde_[a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^{}]*\})?')


def _is_ds_var(value):
    return isinstance(value, str) and _DS_VAR_RE.match(value)


def _is_runtime_datasource_var(value):
    return _is_grafana_var(value) and not _is_ds_var(value)


def _is_grafana_var(value):
    return isinstance(value, str) and _GRAFANA_VAR_RE.match(value)


def _is_ds_variable_name(value):
    return isinstance(value, str) and value.lower().startswith("ds_")


def _collapse_metric_labels(expr, collapse_labels):
    if not collapse_labels:
        return expr

    labels_csv = ",".join(collapse_labels)
    marker = f"without({labels_csv})"

    if marker in expr:
        return expr

    def _wrap_metric(match):
        metric = match.group(1)
        selector = match.group(2) or ""
        return f"max without({labels_csv}) ({metric}{selector})"

    return _HORDE_METRIC_RE.sub(_wrap_metric, expr)


def patch(obj, uid, datasource_name=None, collapse_labels=None, preserve_uids=None):
    """Recursively replace datasource references in legacy and v2 dashboards."""
    if collapse_labels is None:
        collapse_labels = []
    if preserve_uids is None:
        preserve_uids = set()

    if isinstance(obj, dict):
        # Query targets in classic dashboards use `expr`; patching here keeps
        # datasource rewrites and label dedupe in a single recursive pass.
        expr = obj.get("expr")
        if isinstance(expr, str):
            obj["expr"] = _collapse_metric_labels(expr, collapse_labels)

        # Datasource ref shape: {"type": "prometheus", ...}. The only objects
        # in Grafana dashboard JSON that carry `type: "prometheus"` are
        # datasource references (panel/target/variable level). Always pin the
        # target UID, even when `uid` is missing entirely — otherwise Grafana
        # silently falls back to the org's default datasource, which is what
        # was making `instance`/`datname`/`mode` query variables resolve
        # against the wrong tenant.
        #
        # Exception: cross-tenant dashboards (for example the operations
        # overview) hardcode real, provisioned datasource UIDs for other
        # tenants (mimir-app, mimir-telemetry, ...). Those must be preserved
        # so a single-tenant target patch does not collapse every panel onto
        # the target datasource.
        if (
            obj.get("type") == "prometheus"
            and obj.get("uid") not in preserve_uids
            and not (preserve_uids and _is_runtime_datasource_var(obj.get("uid")))
        ):
            obj["uid"] = uid

        # Generic UID replacement for datasource-variable UID placeholders.
        if "uid" in obj and _is_ds_var(obj["uid"]):
            obj["uid"] = uid

        # Grafana v2 panel/query shape often stores datasource as nested object.
        datasource = obj.get("datasource")
        if isinstance(datasource, dict):
            if "uid" in datasource and _is_ds_var(datasource["uid"]):
                datasource["uid"] = uid

            if datasource_name and "uid" in datasource and datasource["uid"] == datasource_name:
                datasource["uid"] = uid

            # Normalize name-based datasource refs to UID-based refs. This keeps
            # dashboard exports from serializing provider names into uid fields.
            if (
                datasource_name
                and "name" in datasource
                and (_is_ds_var(datasource["name"]) or datasource["name"] == datasource_name)
            ):
                datasource["uid"] = uid
                datasource.pop("name", None)

        # V2 QueryVariable blocks in some upstream dashboards omit datasource,
        # which causes Grafana to fall back to org default datasource.
        if obj.get("kind") == "QueryVariable" and isinstance(obj.get("spec"), dict):
            query = obj["spec"].get("query")
            if isinstance(query, dict) and query.get("group") == "prometheus":
                query_ds = query.get("datasource")
                if not isinstance(query_ds, dict):
                    query["datasource"] = {"type": "prometheus", "uid": uid}
                else:
                    query_ds.setdefault("type", "prometheus")
                    if (
                        "uid" not in query_ds
                        or _is_ds_var(query_ds.get("uid"))
                        or (datasource_name and query_ds.get("uid") == datasource_name)
                    ):
                        query_ds["uid"] = uid
                    if (
                        datasource_name
                        and "name" in query_ds
                        and (_is_ds_var(query_ds["name"]) or query_ds["name"] == datasource_name)
                    ):
                        query_ds["uid"] = uid
                        query_ds.pop("name", None)

        # Keep DS_PROMETHEUS variable default aligned with target datasource.
        # Grafana datasource variables use display text = datasource name, but
        # selected value = datasource UID.
        if (
            datasource_name
            and _is_ds_variable_name(obj.get("name"))
            and isinstance(obj.get("current"), dict)
        ):
            obj["current"]["text"] = datasource_name
            obj["current"]["value"] = uid

        # Legacy v1 QueryVariable blocks can carry only datasource type, which
        # also falls back to org default datasource. Pin to target UID.
        if obj.get("type") == "query":
            var_ds = obj.get("datasource")
            if isinstance(var_ds, dict) and var_ds.get("type") == "prometheus":
                if (
                    "uid" not in var_ds
                    or _is_ds_var(var_ds.get("uid"))
                    or (datasource_name and var_ds.get("uid") == datasource_name)
                ):
                    var_ds["uid"] = uid

        for v in obj.values():
            patch(v, uid, datasource_name, collapse_labels, preserve_uids)
    elif isinstance(obj, list):
        for v in obj:
            patch(v, uid, datasource_name, collapse_labels, preserve_uids)


def _strip_v2beta1_server_fields(obj):
    """Strip server-managed bookkeeping from v2beta1 dashboard exports.

    Dashboards exported from Grafana 11.x/12.x via the v2beta1 resource
    API retain ``metadata.managedFields`` and other read-only server-side
    fields. The file provisioner refuses to apply such resources ("the
    field is managed by ..."). Stripping these fields is safe — Grafana
    will repopulate them on the next save — and turns the export back
    into a provisionable dashboard.

    Note: this does NOT silence the separate Grafana 12.x apiserver
    warning ``[SHOULD NOT HAPPEN] failed to update managedFields ...
    .spec.elements.panel-NN.kind: field not declared in schema``. That
    message originates from the v2beta1 schema validator rejecting fields
    in externally-authored dashboard exports. The file provisioner is
    designed for classic v1 JSON; the durable fix lives upstream in
    ``horde-exporters`` (publish dashboards as classic v1 JSON). See
    MONITORING.md → Troubleshooting → "Known harmless log noise".
    """
    if not isinstance(obj, dict):
        return
    metadata = obj.get("metadata")
    if isinstance(metadata, dict):
        for key in (
            "managedFields",
            "creationTimestamp",
            "resourceVersion",
            "generation",
            "uid",
            "deletionTimestamp",
            "ownerReferences",
            "selfLink",
        ):
            metadata.pop(key, None)


def main():
    if len(sys.argv) not in (3, 4, 5, 6):
        print(
            f"Usage: {sys.argv[0]} <dashboard.json> <target-uid> "
            "[target-datasource-name] [collapse-labels-csv] [preserve-uids-csv]",
            file=sys.stderr,
        )
        sys.exit(1)

    path = Path(sys.argv[1])
    uid = sys.argv[2]
    datasource_name = sys.argv[3] if len(sys.argv) >= 4 and sys.argv[3] else None
    collapse_labels = []
    if len(sys.argv) >= 5 and sys.argv[4]:
        collapse_labels = [label.strip() for label in sys.argv[4].split(",") if label.strip()]
    preserve_uids = set()
    if len(sys.argv) == 6 and sys.argv[5]:
        preserve_uids = {u.strip() for u in sys.argv[5].split(",") if u.strip()}

    data = json.loads(path.read_text())
    _strip_v2beta1_server_fields(data)
    patch(data, uid, datasource_name, collapse_labels, preserve_uids)
    path.write_text(json.dumps(data, indent=2) + "\n")


if __name__ == "__main__":
    main()
