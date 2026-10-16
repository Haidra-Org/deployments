"""Public datasource cleanup must retain metrics and authenticated access."""
import itertools
from pathlib import Path
import unittest

import jinja2
import yaml

ROLE = Path(__file__).resolve().parents[2] / "roles/horde_monitoring"


def render(**overrides):
    values = yaml.safe_load((ROLE / "defaults/main.yml").read_text())
    values.update(horde_monitoring__public_org_exists=True)
    values.update(overrides)
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)
    env.filters["bool"] = bool
    return yaml.safe_load(env.from_string(
        (ROLE / "templates/grafana-datasources.yml.j2").read_text()
    ).render(values))


class PublicDatasourcePolicyTest(unittest.TestCase):
    def test_defaults_keep_public_metrics_and_delete_old_raw_telemetry(self):
        config = render()
        self.assertEqual([d["uid"] for d in config["datasources"] if d["orgId"] == 2], ["mimir-public"])
        self.assertEqual({d["name"] for d in config["deleteDatasources"]},
                         {"Tempo", "Loki (AI Horde)", "Pyroscope (AI Horde)"})
        self.assertTrue(all(d["orgId"] == 2 for d in config["deleteDatasources"]))

    def test_public_toggles_do_not_change_internal_datasources(self):
        off = render()
        on = render(horde_monitoring_grafana_public_loki_enabled=True,
                    horde_monitoring_grafana_public_tempo_enabled=True,
                    horde_monitoring_grafana_public_pyroscope_enabled=True)
        self.assertEqual([d for d in off["datasources"] if d["orgId"] == 1],
                         [d for d in on["datasources"] if d["orgId"] == 1])
        self.assertEqual(on["deleteDatasources"], [])

    def test_each_public_opt_in_matches_its_cleanup_policy(self):
        for loki, tempo, profiles in itertools.product([False, True], repeat=3):
            with self.subTest(loki=loki, tempo=tempo, profiles=profiles):
                config = render(horde_monitoring_grafana_public_loki_enabled=loki,
                                horde_monitoring_grafana_public_tempo_enabled=tempo,
                                horde_monitoring_grafana_public_pyroscope_enabled=profiles)
                public = {d["uid"]: d for d in config["datasources"] if d["orgId"] == 2}
                deleted = {d["name"] for d in config["deleteDatasources"]}
                for enabled, uid, name in [(loki, "loki-public", "Loki (AI Horde)"),
                                           (tempo, "tempo-public", "Tempo"),
                                           (profiles, "pyroscope-public", "Pyroscope (AI Horde)")]:
                    self.assertEqual(uid in public, enabled)
                    self.assertEqual(name in deleted, not enabled)
                if tempo:
                    self.assertEqual("tracesToLogsV2" in public["tempo-public"]["jsonData"], loki)

    def test_backend_or_anonymous_disable_still_removes_old_public_copy(self):
        flags = dict(horde_monitoring_grafana_public_loki_enabled=True,
                     horde_monitoring_grafana_public_tempo_enabled=True,
                     horde_monitoring_grafana_public_pyroscope_enabled=True)
        config = render(**flags, horde_monitoring_install_loki=False,
                        horde_monitoring_install_tempo=False,
                        horde_monitoring_install_pyroscope=False)
        self.assertEqual(len(config["deleteDatasources"]), 3)
        config = render(**flags, horde_monitoring_grafana_anonymous_enabled=False)
        self.assertEqual(len(config["deleteDatasources"]), 3)
        self.assertFalse(any(d["orgId"] == 2 for d in config["datasources"]))

    def test_cleanup_uses_configured_public_org_and_names(self):
        config = render(horde_monitoring_grafana_public_org_id=7,
                        horde_monitoring_public_datasource_name="Public metrics")
        self.assertTrue(all(d["orgId"] == 7 for d in config["deleteDatasources"]))
        self.assertIn("Loki (Public metrics)", {d["name"] for d in config["deleteDatasources"]})
        self.assertTrue(all(d["orgId"] in (1, 7) for d in config["datasources"]))


if __name__ == "__main__":
    unittest.main()
